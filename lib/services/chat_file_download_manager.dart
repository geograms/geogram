/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat File Download Manager - Unified download manager for all chat types
 * Handles connection-aware thresholds, progress tracking, and resume capability.
 */

import 'dart:async';
import 'package:path/path.dart' as p;
import '../platform/file_system_service.dart';
import '../util/event_bus.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'storage_config.dart';

/// Connection bandwidth type for threshold determination
enum ConnectionBandwidth {
  ble,      // Bluetooth Low Energy - slowest, use smallest threshold
  lan,      // WiFi/LAN - fast, use larger threshold
  internet, // Internet/Station - varies, use larger threshold
}

/// Download state
enum ChatDownloadStatus {
  idle,        // Not started
  downloading, // In progress
  paused,      // Paused (can resume)
  completed,   // Finished successfully
  failed,      // Failed (can retry)
}

/// Download entry representing a file being downloaded
class ChatDownload {
  final String id;              // Unique identifier (sourceId_filename)
  final String sourceId;        // Callsign or room ID
  final String filename;
  final int expectedBytes;
  int bytesTransferred = 0;
  ChatDownloadStatus status = ChatDownloadStatus.idle;
  String? error;
  double? speedBytesPerSecond;
  String? localPath;            // Final path after completion
  String? tempPath;             // Temporary path during download
  DateTime? startTime;
  DateTime? lastUpdateTime;

  ChatDownload({
    required this.id,
    required this.sourceId,
    required this.filename,
    required this.expectedBytes,
  });

  double get progressPercent =>
      expectedBytes > 0 ? (bytesTransferred / expectedBytes * 100) : 0;

  /// Human-readable file size
  String get fileSizeFormatted => _formatBytes(expectedBytes);

  /// Human-readable transfer speed
  String? get speedFormatted => speedBytesPerSecond != null
      ? '${_formatBytes(speedBytesPerSecond!.toInt())}/s'
      : null;

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  ChatDownload copyWith({
    int? bytesTransferred,
    ChatDownloadStatus? status,
    String? error,
    double? speedBytesPerSecond,
    String? localPath,
    String? tempPath,
    DateTime? startTime,
    DateTime? lastUpdateTime,
  }) {
    final copy = ChatDownload(
      id: id,
      sourceId: sourceId,
      filename: filename,
      expectedBytes: expectedBytes,
    );
    copy.bytesTransferred = bytesTransferred ?? this.bytesTransferred;
    copy.status = status ?? this.status;
    copy.error = error ?? this.error;
    copy.speedBytesPerSecond = speedBytesPerSecond ?? this.speedBytesPerSecond;
    copy.localPath = localPath ?? this.localPath;
    copy.tempPath = tempPath ?? this.tempPath;
    copy.startTime = startTime ?? this.startTime;
    copy.lastUpdateTime = lastUpdateTime ?? this.lastUpdateTime;
    return copy;
  }
}

/// Unified file download manager for all chat types
/// Handles connection-aware thresholds, progress tracking, and resume capability.
class ChatFileDownloadManager {
  static final ChatFileDownloadManager _instance = ChatFileDownloadManager._internal();
  factory ChatFileDownloadManager() => _instance;
  ChatFileDownloadManager._internal();

  // Auto-download thresholds based on connection bandwidth
  static const int bleAutoThreshold = 100 * 1024;       // 100 KB for BLE
  static const int lanAutoThreshold = 5 * 1024 * 1024;  // 5 MB for LAN/WiFi/Internet

  /// Active and completed downloads
  final Map<String, ChatDownload> _downloads = {};

  /// Stream controller for download state changes
  final _downloadController = StreamController<ChatDownload>.broadcast();
  Stream<ChatDownload> get downloadStream => _downloadController.stream;

  /// Check if file should auto-download based on connection type and file size
  bool shouldAutoDownload(ConnectionBandwidth bandwidth, int fileSize) {
    final threshold = bandwidth == ConnectionBandwidth.ble
        ? bleAutoThreshold
        : lanAutoThreshold;
    return fileSize < threshold;
  }

  /// Get connection bandwidth for a device (by callsign)
  /// Determines bandwidth based on active connection methods
  ConnectionBandwidth getDeviceBandwidth(String callsign) {
    final device = DevicesService().getDevice(callsign.toUpperCase());
    if (device == null) return ConnectionBandwidth.internet;

    final methods = device.connectionMethods.map((m) => m.toLowerCase()).toSet();

    // Check for high-bandwidth connections first
    if (methods.any((m) => m.contains('wifi') || m.contains('lan'))) {
      return ConnectionBandwidth.lan;
    }
    if (methods.contains('internet') || methods.contains('station')) {
      return ConnectionBandwidth.internet;
    }
    // BLE is slow - use smallest threshold
    if (methods.contains('bluetooth') || methods.contains('bluetooth_plus')) {
      return ConnectionBandwidth.ble;
    }

    // Default to internet for unknown connection types
    return ConnectionBandwidth.internet;
  }

  /// Get connection bandwidth for station/local (always high bandwidth)
  ConnectionBandwidth getStationBandwidth() => ConnectionBandwidth.lan;

  /// Generate unique download ID
  String generateDownloadId(String sourceId, String filename) {
    return '${sourceId.toUpperCase()}_$filename';
  }

  /// Get download state by ID
  ChatDownload? getDownload(String id) => _downloads[id];

  /// Get download state for a message
  ChatDownload? getDownloadForMessage(String sourceId, String? filename) {
    if (filename == null) return null;
    final id = generateDownloadId(sourceId, filename);
    return _downloads[id];
  }

  /// Check if a download is in progress
  bool isDownloading(String id) {
    final download = _downloads[id];
    return download != null && download.status == ChatDownloadStatus.downloading;
  }

  /// Start download with progress tracking
  ///
  /// [id] - Unique identifier for this download
  /// [sourceId] - The source (callsign or room ID)
  /// [filename] - The filename to download
  /// [expectedBytes] - Expected file size in bytes
  /// [downloadFn] - Function that performs the actual download
  ///   - Takes resumeFrom (bytes already downloaded) and onProgress callback
  ///   - Returns local file path on success, null on failure
  Future<String?> downloadFile({
    required String id,
    required String sourceId,
    required String filename,
    required int expectedBytes,
    required Future<String?> Function(int resumeFrom, void Function(int bytesReceived) onProgress) downloadFn,
  }) async {
    // Check if already downloading
    final existing = _downloads[id];
    if (existing != null && existing.status == ChatDownloadStatus.downloading) {
      LogService().log('ChatFileDownloadManager: Download already in progress: $id');
      return null;
    }

    // Create or resume download entry
    final download = ChatDownload(
      id: id,
      sourceId: sourceId,
      filename: filename,
      expectedBytes: expectedBytes,
    );

    // Check for existing partial download
    final fs = FileSystemService.instance;
    final tempDir = await _getTempDir();
    final tempPath = p.join(tempDir, '${id}_partial');
    int resumeFrom = 0;

    if (await fs.exists(tempPath)) {
      final stat = await fs.stat(tempPath);
      resumeFrom = stat.size;
      download.bytesTransferred = resumeFrom;
      LogService().log('ChatFileDownloadManager: Resuming download from $resumeFrom bytes');
    }

    download.status = ChatDownloadStatus.downloading;
    download.startTime = DateTime.now();
    download.tempPath = tempPath;
    _downloads[id] = download;
    _notifyDownloadChanged(download);

    try {
      // Track speed calculation
      int lastBytes = resumeFrom;
      DateTime lastTime = DateTime.now();

      // Progress callback
      void onProgress(int bytesReceived) {
        final now = DateTime.now();
        final elapsed = now.difference(lastTime).inMilliseconds;

        if (elapsed > 0) {
          final bytesPerMs = (bytesReceived - lastBytes) / elapsed;
          download.speedBytesPerSecond = bytesPerMs * 1000;
        }

        download.bytesTransferred = bytesReceived;
        download.lastUpdateTime = now;
        _downloads[id] = download;
        _notifyDownloadChanged(download);

        lastBytes = bytesReceived;
        lastTime = now;
      }

      // Perform download
      final resultPath = await downloadFn(resumeFrom, onProgress);

      if (resultPath != null) {
        // Success
        download.status = ChatDownloadStatus.completed;
        download.localPath = resultPath;
        download.bytesTransferred = expectedBytes;
        _downloads[id] = download;
        _notifyDownloadChanged(download);

        // Clean up temp file
        if (await fs.exists(tempPath)) {
          await fs.delete(tempPath);
        }

        LogService().log('ChatFileDownloadManager: Download completed: $id -> $resultPath');
        return resultPath;
      } else {
        // Failed
        download.status = ChatDownloadStatus.failed;
        download.error = 'Download returned null';
        _downloads[id] = download;
        _notifyDownloadChanged(download);
        LogService().log('ChatFileDownloadManager: Download failed: $id');
        return null;
      }
    } catch (e) {
      // Error - mark as paused so it can be resumed
      download.status = ChatDownloadStatus.paused;
      download.error = e.toString();
      _downloads[id] = download;
      _notifyDownloadChanged(download);
      LogService().log('ChatFileDownloadManager: Download error: $id - $e');
      return null;
    }
  }

  /// Cancel a download
  Future<void> cancelDownload(String id) async {
    final download = _downloads[id];
    if (download == null) return;

    download.status = ChatDownloadStatus.idle;
    _downloads.remove(id);
    _notifyDownloadChanged(download);

    // Delete temp file
    if (download.tempPath != null) {
      final fs = FileSystemService.instance;
      if (await fs.exists(download.tempPath!)) {
        await fs.delete(download.tempPath!);
      }
    }

    LogService().log('ChatFileDownloadManager: Download cancelled: $id');
  }

  /// Get all paused downloads for a source (for auto-resume on reconnection)
  List<ChatDownload> getPausedDownloads(String sourceId) {
    return _downloads.values
        .where((d) =>
            d.sourceId.toUpperCase() == sourceId.toUpperCase() &&
            d.status == ChatDownloadStatus.paused)
        .toList();
  }

  /// Get all downloads for a source
  List<ChatDownload> getDownloadsForSource(String sourceId) {
    return _downloads.values
        .where((d) => d.sourceId.toUpperCase() == sourceId.toUpperCase())
        .toList();
  }

  /// Clear completed/failed downloads older than the specified duration
  void clearOldDownloads({Duration maxAge = const Duration(hours: 1)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    final toRemove = <String>[];

    for (final entry in _downloads.entries) {
      final download = entry.value;
      if ((download.status == ChatDownloadStatus.completed ||
           download.status == ChatDownloadStatus.failed) &&
          download.lastUpdateTime != null &&
          download.lastUpdateTime!.isBefore(cutoff)) {
        toRemove.add(entry.key);
      }
    }

    for (final id in toRemove) {
      _downloads.remove(id);
    }
  }

  /// Notify listeners of download state change
  void _notifyDownloadChanged(ChatDownload download) {
    if (!_downloadController.isClosed) {
      _downloadController.add(download);
    }

    // Also fire event bus event for cross-widget updates
    EventBus().fire(ChatDownloadProgressEvent(
      downloadId: download.id,
      bytesTransferred: download.bytesTransferred,
      totalBytes: download.expectedBytes,
      speedBytesPerSecond: download.speedBytesPerSecond,
      status: download.status,
    ));
  }

  /// Get temp directory for partial downloads
  Future<String> _getTempDir() async {
    final baseDir = StorageConfig().baseDir;
    final tempDir = p.join(baseDir, 'temp', 'downloads');
    final fs = FileSystemService.instance;
    if (!await fs.isDirectory(tempDir)) {
      await fs.createDirectory(tempDir, recursive: true);
    }
    return tempDir;
  }

  /// Dispose resources
  void dispose() {
    _downloadController.close();
  }
}

/// Format bytes to human-readable string (utility function)
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
