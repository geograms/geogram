import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../../connection/connection_manager.dart';
import '../../services/log_service.dart';
import '../../util/event_bus.dart';
import '../models/transfer_models.dart';

/// Callback for transfer progress updates
typedef TransferProgressCallback = void Function(
  Transfer transfer,
  int bytesTransferred,
  double? speedBytesPerSecond,
);

/// Callback for transfer completion
typedef TransferCompleteCallback = void Function(
  Transfer transfer,
  bool success,
  String? error,
);

/// Individual transfer worker that processes one transfer at a time
///
/// Lifecycle:
/// 1. Receive transfer from pool
/// 2. Update status to 'connecting'
/// 3. Use ConnectionManager to reach remote peer
/// 4. Execute transfer protocol
/// 5. Verify integrity (hash check)
/// 6. Move to final destination
/// 7. Fire completion event
class TransferWorker {
  final String workerId;
  final LogService _log = LogService();
  final EventBus _eventBus = EventBus();

  Transfer? _currentTransfer;
  bool _cancelled = false;
  DateTime? _transferStartTime;
  int _lastProgressBytes = 0;
  DateTime? _lastProgressTime;

  /// Callback for progress updates
  TransferProgressCallback? onProgress;

  /// Callback for transfer completion
  TransferCompleteCallback? onComplete;

  TransferWorker({required this.workerId});

  /// Check if worker is busy
  bool get isBusy => _currentTransfer != null;

  /// Get current transfer
  Transfer? get currentTransfer => _currentTransfer;

  /// Process a transfer
  Future<void> processTransfer(Transfer transfer) async {
    if (_currentTransfer != null) {
      throw StateError('Worker $workerId is already processing a transfer');
    }

    _currentTransfer = transfer;
    _cancelled = false;
    _transferStartTime = DateTime.now();
    _lastProgressBytes = 0;
    _lastProgressTime = DateTime.now();

    try {
      transfer.status = TransferStatus.connecting;
      transfer.startedAt = DateTime.now();
      _reportProgress(transfer, 0, null);

      switch (transfer.direction) {
        case TransferDirection.download:
          await _executeDownload(transfer);
          break;
        case TransferDirection.upload:
          await _executeUpload(transfer);
          break;
        case TransferDirection.stream:
          await _executeStream(transfer);
          break;
      }
    } catch (e, stack) {
      _log.log('TransferWorker $workerId: Error processing ${transfer.id}: $e');
      _log.log('Stack: $stack');

      transfer.status = TransferStatus.failed;
      transfer.error = e.toString();
      transfer.lastActivityAt = DateTime.now();

      onComplete?.call(transfer, false, e.toString());
    } finally {
      _currentTransfer = null;
      _transferStartTime = null;
    }
  }

  /// Cancel the current transfer
  void cancel() {
    _cancelled = true;
  }

  /// Execute a download transfer
  Future<void> _executeDownload(Transfer transfer) async {
    if (_cancelled) throw Exception('Transfer cancelled');

    // Create temp file for download
    final tempPath = '${transfer.localPath}.tmp';
    final tempFile = File(tempPath);

    try {
      // Ensure parent directory exists
      await tempFile.parent.create(recursive: true);

      transfer.status = TransferStatus.transferring;
      _reportProgress(transfer, 0, null);

      // Use ConnectionManager to download
      final cm = ConnectionManager();
      final isBotModelPath = transfer.remotePath == '/bot/models' ||
          transfer.remotePath.startsWith('/bot/models/');
      final requestPath = isBotModelPath
          ? Uri.encodeFull(transfer.remotePath)
          : '/api/files/content?path=${Uri.encodeComponent(transfer.remotePath)}';
      final timeout = transfer.timeout ?? const Duration(minutes: 10);

      Uint8List? inMemoryBytes;
      int bytesWritten = 0;

      if (isBotModelPath && transfer.sourceStationUrl != null) {
        bytesWritten = await _streamDownloadFromStation(
          transfer,
          requestPath,
          tempFile,
          timeout: timeout,
        );
        transfer.transportUsed = 'station_http';
      } else {
        final result = await cm.apiRequest(
          callsign: transfer.sourceCallsign,
          method: 'GET',
          path: requestPath,
          timeout: timeout,
        );

        if (_cancelled) throw Exception('Transfer cancelled');

        if (result.wasQueued) {
          throw Exception('Download queued but no response received');
        }

        if (!result.success) {
          throw Exception(
              'Download failed: ${result.error ?? 'Unknown error'} (${result.statusCode})');
        }

        final statusCode = result.statusCode;
        if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
          throw Exception('Download failed: HTTP $statusCode');
        }

        // Write response to temp file
        if (result.responseData is String) {
          // Base64 encoded
          inMemoryBytes = base64Decode(result.responseData as String);
        } else if (result.responseData is List<int>) {
          inMemoryBytes = Uint8List.fromList(result.responseData as List<int>);
        } else {
          throw Exception(
              'Unexpected response type: ${result.responseData.runtimeType}');
        }

        await tempFile.writeAsBytes(inMemoryBytes);
        bytesWritten = inMemoryBytes.length;
        transfer.transportUsed = result.transportUsed;

        transfer.bytesTransferred = bytesWritten;
      }

      _reportProgress(
          transfer, bytesWritten, _calculateSpeed(bytesWritten));

      if (_cancelled) {
        await tempFile.delete();
        throw Exception('Transfer cancelled');
      }

      // Verify file size
      transfer.status = TransferStatus.verifying;
      _reportProgress(transfer, bytesWritten, null);

      final expectedBytes = transfer.expectedBytes;
      if (expectedBytes > 0) {
        final toleranceRatio = _getSizeToleranceRatio(transfer);
        final tolerance = (expectedBytes * toleranceRatio).round();
        if ((bytesWritten - expectedBytes).abs() > tolerance) {
          await tempFile.delete();
          throw Exception(
              'Size mismatch: expected $expectedBytes, got $bytesWritten');
        }
      }

      // Verify hash if provided
      if (transfer.expectedHash != null && transfer.expectedHash!.isNotEmpty) {
        final bytesForHash =
            inMemoryBytes ?? await tempFile.readAsBytes();
        final hash = sha256.convert(bytesForHash).toString();
        final expectedHash = transfer.expectedHash!.replaceFirst('sha256:', '');
        if (hash != expectedHash) {
          await tempFile.delete();
          throw Exception('Hash mismatch: expected $expectedHash, got $hash');
        }
      }

      // Move to final location
      final finalFile = File(transfer.localPath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tempFile.rename(transfer.localPath);

      // Mark as complete
      transfer.status = TransferStatus.completed;
      transfer.completedAt = DateTime.now();
      transfer.lastActivityAt = DateTime.now();

      final duration = transfer.completedAt!.difference(transfer.startedAt!);
      transfer.speedBytesPerSecond =
          duration.inMilliseconds > 0
              ? bytesWritten / (duration.inMilliseconds / 1000)
              : 0;

      _log.log(
          'TransferWorker $workerId: Download complete ${transfer.id} via ${transfer.transportUsed}');

      onComplete?.call(transfer, true, null);

      // Fire event
      _eventBus.fire(TransferCompletedEvent(
        transferId: transfer.id,
        direction: TransferEventDirection.download,
        callsign: transfer.sourceCallsign,
        localPath: transfer.localPath,
        totalBytes: bytesWritten,
        duration: duration,
        transportUsed: transfer.transportUsed ?? 'unknown',
        requestingApp: transfer.requestingApp,
        metadata: transfer.metadata,
      ));
    } catch (e) {
      // Clean up temp file on error
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<int> _streamDownloadFromStation(
    Transfer transfer,
    String requestPath,
    File tempFile, {
    required Duration timeout,
  }) async {
    final stationUrl = transfer.sourceStationUrl!;
    final httpBase = _resolveHttpBase(stationUrl);
    final baseUri = Uri.parse(httpBase);
    final uri = baseUri.resolve(requestPath);

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      final response = await client.send(request).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      if (response.contentLength != null && response.contentLength! > 0) {
        transfer.expectedBytes = response.contentLength!;
      }

      final sink = tempFile.openWrite();
      var bytesWritten = 0;

      await for (final chunk in response.stream.timeout(timeout)) {
        if (_cancelled) {
          await sink.close();
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
          throw Exception('Transfer cancelled');
        }
        sink.add(chunk);
        bytesWritten += chunk.length;
        _reportProgress(
            transfer, bytesWritten, _calculateSpeed(bytesWritten));
      }

      await sink.close();
      return bytesWritten;
    } finally {
      client.close();
    }
  }

  String _resolveHttpBase(String stationUrl) {
    if (stationUrl.startsWith('http://') ||
        stationUrl.startsWith('https://')) {
      return stationUrl;
    }
    if (stationUrl.startsWith('ws://')) {
      return stationUrl.replaceFirst('ws://', 'http://');
    }
    if (stationUrl.startsWith('wss://')) {
      return stationUrl.replaceFirst('wss://', 'https://');
    }
    return stationUrl;
  }

  double _getSizeToleranceRatio(Transfer transfer) {
    final metadata = transfer.metadata;
    if (metadata == null) return 0.0;
    final ratio = metadata['size_tolerance_ratio'];
    if (ratio is num && ratio >= 0) {
      return ratio.toDouble();
    }
    return 0.0;
  }

  /// Execute an upload transfer
  Future<void> _executeUpload(Transfer transfer) async {
    if (_cancelled) throw Exception('Transfer cancelled');

    final sourceFile = File(transfer.localPath);
    if (!await sourceFile.exists()) {
      throw Exception('Source file not found: ${transfer.localPath}');
    }

    final bytes = await sourceFile.readAsBytes();

    transfer.status = TransferStatus.transferring;
    _reportProgress(transfer, 0, null);

    // Use ConnectionManager to upload
    final cm = ConnectionManager();
    final encodedPath = Uri.encodeComponent(transfer.remotePath);

    final result = await cm.apiRequest(
      callsign: transfer.targetCallsign,
      method: 'POST',
      path: '/api/files/upload?path=$encodedPath',
      body: {
        'content': base64Encode(bytes),
        'size': bytes.length,
        'filename': path.basename(transfer.localPath),
        'mime_type': transfer.mimeType,
      },
      timeout: transfer.timeout ?? const Duration(minutes: 10),
    );

    if (_cancelled) throw Exception('Transfer cancelled');

    if (!result.success) {
      throw Exception(
          'Upload failed: ${result.error ?? 'Unknown error'} (${result.statusCode})');
    }

    transfer.bytesTransferred = bytes.length;
    transfer.transportUsed = result.transportUsed;

    // Mark as complete
    transfer.status = TransferStatus.completed;
    transfer.completedAt = DateTime.now();
    transfer.lastActivityAt = DateTime.now();

    final duration = transfer.completedAt!.difference(transfer.startedAt!);
    transfer.speedBytesPerSecond =
        duration.inMilliseconds > 0
            ? bytes.length / (duration.inMilliseconds / 1000)
            : 0;

    _log.log(
        'TransferWorker $workerId: Upload complete ${transfer.id} via ${transfer.transportUsed}');

    onComplete?.call(transfer, true, null);

    // Fire event
    _eventBus.fire(TransferCompletedEvent(
      transferId: transfer.id,
      direction: TransferEventDirection.upload,
      callsign: transfer.targetCallsign,
      localPath: transfer.localPath,
      totalBytes: bytes.length,
      duration: duration,
      transportUsed: transfer.transportUsed ?? 'unknown',
      requestingApp: transfer.requestingApp,
      metadata: transfer.metadata,
    ));
  }

  /// Execute a stream transfer (placeholder for future implementation)
  Future<void> _executeStream(Transfer transfer) async {
    // Streaming is more complex and would require WebSocket or similar
    // For now, treat as a regular download
    _log.log('TransferWorker $workerId: Stream mode not fully implemented, treating as download');
    await _executeDownload(transfer);
  }

  /// Report progress
  void _reportProgress(Transfer transfer, int bytes, double? speed) {
    transfer.bytesTransferred = bytes;
    transfer.speedBytesPerSecond = speed;
    transfer.lastActivityAt = DateTime.now();

    if (transfer.expectedBytes > 0 && speed != null && speed > 0) {
      final remaining = transfer.expectedBytes - bytes;
      final secondsRemaining = remaining / speed;
      transfer.estimatedTimeRemaining = Duration(seconds: secondsRemaining.round());
    }

    onProgress?.call(transfer, bytes, speed);

    // Fire progress event (throttled - let caller handle throttling)
    _eventBus.fire(TransferProgressEvent(
      transferId: transfer.id,
      status: transfer.status.name,
      bytesTransferred: bytes,
      totalBytes: transfer.expectedBytes,
      speedBytesPerSecond: speed,
      eta: transfer.estimatedTimeRemaining,
    ));
  }

  /// Calculate transfer speed
  double? _calculateSpeed(int currentBytes) {
    if (_transferStartTime == null) return null;

    final now = DateTime.now();
    final elapsed = now.difference(_transferStartTime!);

    if (elapsed.inMilliseconds > 0) {
      return currentBytes / (elapsed.inMilliseconds / 1000);
    }

    return null;
  }
}
