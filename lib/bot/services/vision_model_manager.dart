/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/vision_model_info.dart';
import '../../services/log_service.dart';
import '../../services/station_service.dart';
import '../../services/storage_config.dart';
import '../../transfer/models/transfer_models.dart';
import '../../transfer/services/transfer_service.dart';
import '../../util/event_bus.dart';

/// Manages vision model downloads and storage
class VisionModelManager {
  static final VisionModelManager _instance = VisionModelManager._internal();
  factory VisionModelManager() => _instance;
  VisionModelManager._internal();

  /// Directory for storing vision models
  String? _modelsPath;

  /// Transfer service for downloading models
  final TransferService _transferService = TransferService();
  final EventBus _eventBus = EventBus();

  /// Maps model IDs to their active transfer IDs
  final Map<String, String> _modelTransferIds = {};

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

    _modelsPath = p.join(storageConfig.baseDir, 'bot', 'models', 'vision');

    // Create directory if it doesn't exist
    final dir = Directory(_modelsPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    LogService().log('VisionModelManager: Initialized at $_modelsPath');
  }

  /// Get path to models directory
  Future<String> get modelsPath async {
    if (_modelsPath == null) {
      await initialize();
    }
    return _modelsPath!;
  }

  /// Get path to a specific model file
  Future<String> getModelPath(String modelId) async {
    final basePath = await modelsPath;
    final model = VisionModels.getById(modelId);
    if (model == null) {
      throw ArgumentError('Unknown model: $modelId');
    }
    final extension = model.format == 'tflite' ? '.tflite' : '.gguf';
    return '$basePath/$modelId$extension';
  }

  /// Check if a model is downloaded
  Future<bool> isDownloaded(String modelId) async {
    try {
      final path = await getModelPath(modelId);
      final file = File(path);
      if (!await file.exists()) return false;

      // Verify file size matches expected
      final model = VisionModels.getById(modelId);
      if (model == null) return false;

      final actualSize = await file.length();
      // Allow 5% tolerance for size difference
      final tolerance = model.size * 0.05;
      return (actualSize - model.size).abs() < tolerance;
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

  /// Download a model with progress tracking via TransferService
  ///
  /// Downloads are routed through the Transfer app which uses ConnectionManager
  /// to find the best transport (LAN, WebRTC, Station, BLE+, BLE).
  ///
  /// Models are downloaded from stations at /bot/models/vision/{modelId}.{extension}
  ///
  /// Returns a stream of progress updates (0.0 - 1.0)
  Stream<double> downloadModel(
    String modelId, {
    String? stationUrl,
    String? stationCallsign,
  }) async* {
    final model = VisionModels.getById(modelId);
    if (model == null) {
      throw ArgumentError('Unknown model: $modelId');
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

    final localPath = await getModelPath(modelId);
    final extension = model.format == 'tflite' ? 'tflite' : 'gguf';
    final remotePath = '/bot/models/vision/$modelId.$extension';

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

    // Check if transfer already exists
    var transfer = _transferService.findTransfer(
      callsign: resolvedCallsign,
      remotePath: remotePath,
    );

    if (transfer == null) {
      // Create new transfer request
      LogService().log(
          'VisionModelManager: Requesting transfer for $modelId from station $resolvedCallsign');

      // Create parent directory if needed
      final parentDir = Directory(localPath).parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      transfer = await _transferService.requestDownload(
        TransferRequest(
          direction: TransferDirection.download,
          callsign: resolvedCallsign,
          stationUrl: resolvedStationUrl,
          remotePath: remotePath,
          localPath: localPath,
          expectedBytes: model.size,
          timeout: const Duration(hours: 2),
          priority: TransferPriority.high,
          requestingApp: 'bot',
          metadata: {
            'model_id': modelId,
            'model_type': 'vision',
            'model_name': model.name,
            'model_tier': model.tier,
            'size_tolerance_ratio': 0.05,
          },
        ),
      );
    }

    // Track the transfer
    _modelTransferIds[modelId] = transfer.id;
    _activeDownloads[modelId] = _DownloadProgress();
    _downloadStateController.add(modelId);

    // Create a completer to track completion
    final completer = Completer<void>();
    String? errorMessage;

    // Subscribe to progress events
    final progressSub = _eventBus.on<TransferProgressEvent>((event) {
      if (event.transferId == transfer!.id) {
        final progress = event.totalBytes > 0
            ? event.bytesTransferred / event.totalBytes
            : 0.0;
        _activeDownloads[modelId]?.progress = progress;
      }
    });

    // Subscribe to completion events
    final completeSub = _eventBus.on<TransferCompletedEvent>((event) {
      if (event.transferId == transfer!.id) {
        _activeDownloads[modelId]?.progress = 1.0;
        if (!completer.isCompleted) completer.complete();
      }
    });

    // Subscribe to failure events
    final failedSub = _eventBus.on<TransferFailedEvent>((event) {
      if (event.transferId == transfer!.id && !event.willRetry) {
        errorMessage = event.error;
        if (!completer.isCompleted) completer.completeError(Exception(event.error));
      }
    });

    try {
      // Yield progress updates until transfer completes
      while (!completer.isCompleted) {
        final progress = _activeDownloads[modelId]?.progress ?? 0.0;
        yield progress;

        if (progress >= 1.0) break;

        // Check transfer status periodically
        final currentTransfer = _transferService.getTransfer(transfer.id);
        if (currentTransfer != null) {
          if (currentTransfer.isCompleted) {
            yield 1.0;
            break;
          }
          if (currentTransfer.isFailed) {
            throw Exception(currentTransfer.error ?? 'Transfer failed');
          }
        }

        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Wait for completion
      await completer.future;
      LogService().log('VisionModelManager: Downloaded $modelId via TransferService');
      yield 1.0;
    } catch (e) {
      LogService().log('VisionModelManager: Error downloading $modelId: $e');
      rethrow;
    } finally {
      // Cleanup subscriptions
      progressSub.cancel();
      completeSub.cancel();
      failedSub.cancel();

      _activeDownloads.remove(modelId);
      _modelTransferIds.remove(modelId);
      _downloadStateController.add(modelId);
    }
  }

  /// Get the transfer ID for a model download (if in progress)
  String? getTransferId(String modelId) => _modelTransferIds[modelId];

  /// Get the current transfer for a model (if in progress)
  Transfer? getTransfer(String modelId) {
    final transferId = _modelTransferIds[modelId];
    if (transferId == null) return null;
    return _transferService.getTransfer(transferId);
  }

  /// Delete a downloaded model
  Future<void> deleteModel(String modelId) async {
    // Cancel if downloading
    if (_activeDownloads.containsKey(modelId)) {
      _activeDownloads.remove(modelId);
    }

    final path = await getModelPath(modelId);
    final file = File(path);

    if (await file.exists()) {
      await file.delete();
      LogService().log('VisionModelManager: Deleted model $modelId');
    }

    // Also delete temp file if exists
    final tempFile = File('$path.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    _downloadStateController.add(modelId);
  }

  /// Get list of downloaded models
  Future<List<VisionModelInfo>> getDownloadedModels() async {
    final downloaded = <VisionModelInfo>[];

    for (final model in VisionModels.available) {
      if (await isDownloaded(model.id)) {
        downloaded.add(model);
      }
    }

    return downloaded;
  }

  /// Get total storage used by vision models in bytes
  Future<int> getTotalStorageUsed() async {
    var total = 0;

    for (final model in VisionModels.available) {
      try {
        final path = await getModelPath(model.id);
        final file = File(path);
        if (await file.exists()) {
          total += await file.length();
        }
      } catch (_) {
        // Ignore errors
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

  /// Clear all downloaded vision models
  Future<void> clearAllModels() async {
    for (final model in VisionModels.available) {
      await deleteModel(model.id);
    }
    LogService().log('VisionModelManager: Cleared all vision models');
  }

  /// Get recommended models based on device RAM
  List<VisionModelInfo> getRecommendedModels(int availableRamMb) {
    return VisionModels.available
        .where((m) => m.minRamMb <= availableRamMb)
        .toList();
  }

  void dispose() {
    _downloadStateController.close();
  }
}

/// Tracks download progress for a model
class _DownloadProgress {
  double progress = 0.0;
}
