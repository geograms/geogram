/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/music_model_info.dart';
import '../../services/log_service.dart';
import '../../services/station_service.dart';
import '../../services/storage_config.dart';
import '../../transfer/models/transfer_models.dart';
import '../../transfer/services/transfer_service.dart';
import '../../util/event_bus.dart';

/// Manages music generation model downloads and storage.
/// Downloads are routed through TransferService which uses ConnectionManager
/// to find the best transport (LAN, WebRTC, Station, BLE+, BLE).
class MusicModelManager {
  static final MusicModelManager _instance = MusicModelManager._internal();
  factory MusicModelManager() => _instance;
  MusicModelManager._internal();

  /// Directory for storing music models
  String? _modelsPath;

  /// Transfer service for downloading models
  final TransferService _transferService = TransferService();
  final EventBus _eventBus = EventBus();

  /// Maps model IDs to their active transfer IDs (supports multi-file models)
  final Map<String, List<String>> _modelTransferIds = {};

  /// Currently downloading models (for backward compatibility with UI)
  final Map<String, _DownloadProgress> _activeDownloads = {};

  /// Notifier for download state changes
  final StreamController<String> _downloadStateController =
      StreamController<String>.broadcast();

  /// Stream of model IDs when their download state changes
  Stream<String> get downloadStateChanges => _downloadStateController.stream;

  /// Initialize the manager
  Future<void> initialize() async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      await storageConfig.init();
    }

    _modelsPath = p.join(storageConfig.baseDir, 'bot', 'models', 'music');

    // Create directory if it doesn't exist
    final dir = Directory(_modelsPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    LogService().log('MusicModelManager: Initialized at $_modelsPath');
  }

  /// Get path to models directory
  Future<String> get modelsPath async {
    if (_modelsPath == null) {
      await initialize();
    }
    return _modelsPath!;
  }

  /// Get path to a specific model directory
  Future<String> getModelDir(String modelId) async {
    final basePath = await modelsPath;
    final model = MusicModels.getById(modelId);
    if (model == null) {
      throw ArgumentError('Unknown model: $modelId');
    }

    // FM synth doesn't have a file
    if (model.isNative) {
      throw ArgumentError('Native model $modelId has no directory');
    }

    return p.join(basePath, modelId);
  }

  /// Get path to a specific model file (relative to model directory)
  Future<String> getModelFilePath(String modelId, String relativePath) async {
    final modelDir = await getModelDir(modelId);
    return p.join(modelDir, relativePath);
  }

  /// Check if a model is downloaded
  Future<bool> isDownloaded(String modelId) async {
    final model = MusicModels.getById(modelId);
    if (model == null) return false;

    // FM synth is always "downloaded" (native)
    if (model.isNative) return true;

    try {
      if (model.files.isEmpty) {
        // Legacy single-file model fallback
        final extension = model.format == 'onnx' ? '.onnx' : '.tflite';
        final legacyPath = p.join(await modelsPath, '$modelId$extension');
        final file = File(legacyPath);
        if (!await file.exists()) return false;

        if (model.size > 0) {
          final actualSize = await file.length();
          final tolerance = model.size * 0.05;
          return (actualSize - model.size).abs() < tolerance;
        }
        return true;
      }

      for (final fileInfo in model.files) {
        final filePath = await getModelFilePath(modelId, fileInfo.path);
        final file = File(filePath);
        if (!await file.exists()) return false;

        if (fileInfo.size > 0) {
          final actualSize = await file.length();
          final tolerance = fileInfo.size * 0.05;
          if ((actualSize - fileInfo.size).abs() >= tolerance) {
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if a model is currently downloading
  bool isDownloading(String modelId) => _activeDownloads.containsKey(modelId);

  /// Get download progress (0.0 - 1.0) for a model
  double getDownloadProgress(String modelId) {
    return _activeDownloads[modelId]?.progress ?? 0.0;
  }

  /// Download a model with progress tracking via TransferService.
  ///
  /// Downloads are routed through the Transfer app which uses ConnectionManager
  /// to find the best transport (LAN, WebRTC, Station, BLE+, BLE).
  ///
  /// Multi-file models create separate transfers for each file, with
  /// aggregate progress tracking.
  ///
  /// Returns a stream of progress updates (0.0 - 1.0)
  Stream<double> downloadModel(
    String modelId, {
    String? stationUrl,
    String? stationCallsign,
  }) async* {
    final model = MusicModels.getById(modelId);
    if (model == null) {
      throw ArgumentError('Unknown model: $modelId');
    }

    // Native models don't need downloading
    if (model.isNative) {
      yield 1.0;
      return;
    }

    // Check if already downloaded
    if (await isDownloaded(modelId)) {
      yield 1.0;
      return;
    }

    // Ensure TransferService is initialized
    if (!_transferService.isInitialized) {
      await _transferService.initialize();
    }

    // Get station info for the transfer
    final preferredStation = StationService().getPreferredStation();
    final resolvedStationUrl = stationUrl ?? preferredStation?.url;
    final resolvedCallsign = stationCallsign ?? preferredStation?.callsign;
    if (resolvedStationUrl == null ||
        resolvedStationUrl.isEmpty ||
        resolvedCallsign == null ||
        resolvedCallsign.isEmpty) {
      throw Exception(
          'No station configured. Please connect to a station to download models.');
    }

    // Build file list (single file for legacy models, multiple for new)
    final files = model.files.isNotEmpty
        ? model.files
        : [
            MusicModelFile(
              path: '$modelId.${model.format == 'onnx' ? 'onnx' : 'tflite'}',
              size: model.size,
            )
          ];

    // Track download
    _activeDownloads[modelId] = _DownloadProgress();
    _modelTransferIds[modelId] = [];
    _downloadStateController.add(modelId);

    // Track progress per file
    final fileProgress = <int, double>{};
    final completers = <Completer<void>>[];
    final subscriptions = <EventSubscription>[];

    try {
      // Create transfers for each file
      for (var i = 0; i < files.length; i++) {
        final fileInfo = files[i];
        final localPath = model.files.isNotEmpty
            ? await getModelFilePath(modelId, fileInfo.path)
            : p.join(await modelsPath, fileInfo.path);
        final remotePath = '/bot/models/music/$modelId/${fileInfo.path}';

        // Create parent directory if needed
        final parentDir = Directory(localPath).parent;
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        // Skip if file already downloaded
        final localFile = File(localPath);
        if (await localFile.exists()) {
          if (fileInfo.size > 0) {
            final actualSize = await localFile.length();
            final tolerance = fileInfo.size * 0.05;
            if ((actualSize - fileInfo.size).abs() < tolerance) {
              fileProgress[i] = 1.0;
              continue;
            }
          } else {
            fileProgress[i] = 1.0;
            continue;
          }
        }

        // Check if transfer already exists
        var transfer = _transferService.findTransfer(
          callsign: resolvedCallsign,
          remotePath: remotePath,
        );

        if (transfer == null) {
          LogService().log(
              'MusicModelManager: Requesting transfer for $modelId (${fileInfo.path}) from station $resolvedCallsign');

          transfer = await _transferService.requestDownload(
            TransferRequest(
              direction: TransferDirection.download,
              callsign: resolvedCallsign,
              stationUrl: resolvedStationUrl,
              remotePath: remotePath,
              localPath: localPath,
              expectedBytes: fileInfo.size,
              timeout: const Duration(hours: 2),
              priority: TransferPriority.high,
              requestingApp: 'bot',
              metadata: {
                'model_id': modelId,
                'model_type': 'music',
                'model_name': model.name,
                'file_index': i,
                'file_path': fileInfo.path,
                'size_tolerance_ratio': 0.05,
              },
            ),
          );
        }

        _modelTransferIds[modelId]!.add(transfer.id);
        fileProgress[i] = 0.0;

        // Create completer for this file
        final completer = Completer<void>();
        completers.add(completer);

        // Subscribe to progress events for this file
        final progressSub = _eventBus.on<TransferProgressEvent>((event) {
          if (event.transferId == transfer!.id) {
            final progress = event.totalBytes > 0
                ? event.bytesTransferred / event.totalBytes
                : 0.0;
            fileProgress[i] = progress;
          }
        });
        subscriptions.add(progressSub);

        // Subscribe to completion events
        final completeSub = _eventBus.on<TransferCompletedEvent>((event) {
          if (event.transferId == transfer!.id) {
            fileProgress[i] = 1.0;
            if (!completer.isCompleted) completer.complete();
          }
        });
        subscriptions.add(completeSub);

        // Subscribe to failure events
        final failedSub = _eventBus.on<TransferFailedEvent>((event) {
          if (event.transferId == transfer!.id && !event.willRetry) {
            if (!completer.isCompleted) {
              completer.completeError(Exception(event.error));
            }
          }
        });
        subscriptions.add(failedSub);
      }

      // Yield progress updates until all files complete
      while (!completers.every((c) => c.isCompleted)) {
        // Calculate aggregate progress
        var totalProgress = 0.0;
        for (var i = 0; i < files.length; i++) {
          totalProgress += (fileProgress[i] ?? 0.0) / files.length;
        }

        _activeDownloads[modelId]!.progress = totalProgress;
        yield totalProgress;

        if (totalProgress >= 1.0) break;

        // Check transfer status periodically
        var allComplete = true;
        var anyFailed = false;
        String? failError;

        for (final transferId in _modelTransferIds[modelId] ?? []) {
          final currentTransfer = _transferService.getTransfer(transferId);
          if (currentTransfer != null) {
            if (currentTransfer.isFailed) {
              anyFailed = true;
              failError = currentTransfer.error;
              break;
            }
            if (!currentTransfer.isCompleted) {
              allComplete = false;
            }
          }
        }

        if (anyFailed) {
          throw Exception(failError ?? 'Transfer failed');
        }

        if (allComplete && fileProgress.values.every((p) => p >= 1.0)) {
          break;
        }

        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Wait for all completers
      await Future.wait(completers.map((c) => c.future));

      LogService()
          .log('MusicModelManager: Downloaded $modelId via TransferService');
      yield 1.0;
    } catch (e) {
      LogService().log('MusicModelManager: Error downloading $modelId: $e');
      rethrow;
    } finally {
      // Cleanup subscriptions
      for (final sub in subscriptions) {
        sub.cancel();
      }

      _activeDownloads.remove(modelId);
      _modelTransferIds.remove(modelId);
      _downloadStateController.add(modelId);
    }
  }

  /// Get the transfer IDs for a model download (if in progress)
  List<String>? getTransferIds(String modelId) => _modelTransferIds[modelId];

  /// Get the current transfers for a model (if in progress)
  List<Transfer> getTransfers(String modelId) {
    final transferIds = _modelTransferIds[modelId];
    if (transferIds == null) return [];
    return transferIds
        .map((id) => _transferService.getTransfer(id))
        .whereType<Transfer>()
        .toList();
  }

  /// Delete a downloaded model
  Future<void> deleteModel(String modelId) async {
    final model = MusicModels.getById(modelId);
    if (model == null || model.isNative) return;

    // Cancel if downloading
    if (_activeDownloads.containsKey(modelId)) {
      _activeDownloads.remove(modelId);
    }

    final dir = Directory(await getModelDir(modelId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      LogService().log('MusicModelManager: Deleted model $modelId');
    }

    _downloadStateController.add(modelId);
  }

  /// Get list of downloaded AI models (excludes FM synth)
  Future<List<MusicModelInfo>> getDownloadedModels() async {
    final downloaded = <MusicModelInfo>[];

    for (final model in MusicModels.aiModels) {
      if (await isDownloaded(model.id)) {
        downloaded.add(model);
      }
    }

    return downloaded;
  }

  /// Get the best available model for the device.
  Future<MusicModelInfo> getBestAvailableModel(int availableRamMb) async {
    final recommended = MusicModels.selectForRam(availableRamMb);
    if (!recommended.isNative && await isDownloaded(recommended.id)) {
      return recommended;
    }

    final downloaded = await getDownloadedModels();
    if (downloaded.isNotEmpty) {
      downloaded.sort((a, b) => b.size.compareTo(a.size));
      return downloaded.first;
    }

    return MusicModels.fmSynth;
  }

  /// Get recommended model for device RAM (may not be downloaded)
  MusicModelInfo getRecommendedModel(int availableRamMb) {
    return MusicModels.selectForRam(availableRamMb);
  }

  /// Get total storage used by music models in bytes
  Future<int> getTotalStorageUsed() async {
    var total = 0;

    for (final model in MusicModels.aiModels) {
      if (model.files.isEmpty) {
        try {
          final extension = model.format == 'onnx' ? '.onnx' : '.tflite';
          final legacyPath = p.join(await modelsPath, '${model.id}$extension');
          final file = File(legacyPath);
          if (await file.exists()) {
            total += await file.length();
          }
        } catch (_) {
          // Ignore errors
        }
      } else {
        for (final fileInfo in model.files) {
          try {
            final filePath = await getModelFilePath(model.id, fileInfo.path);
            final file = File(filePath);
            if (await file.exists()) {
              total += await file.length();
            }
          } catch (_) {
            // Ignore errors
          }
        }
      }
    }

    return total;
  }

  /// Get human-readable storage used string
  Future<String> getStorageUsedString() async {
    final bytes = await getTotalStorageUsed();

    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Clear all downloaded music models
  Future<void> clearAllModels() async {
    for (final model in MusicModels.aiModels) {
      await deleteModel(model.id);
    }
    LogService().log('MusicModelManager: Cleared all music models');
  }

  void dispose() {
    _downloadStateController.close();
  }
}

/// Tracks download progress for a model
class _DownloadProgress {
  double progress = 0.0;
}
