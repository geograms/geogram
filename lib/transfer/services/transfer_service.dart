import 'dart:async';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../services/log_service.dart';
import '../../util/event_bus.dart';
import '../models/transfer_metrics.dart';
import '../models/transfer_models.dart';
import 'transfer_metrics_service.dart';
import 'transfer_queue.dart';
import 'transfer_storage.dart';
import 'transfer_worker_pool.dart';

/// TransferService - Main entry point for file transfers
///
/// This is a singleton service that provides a unified API for:
/// - Requesting file downloads from remote peers
/// - Uploading files to remote peers
/// - Streaming data bidirectionally
/// - Querying transfer status
/// - Managing transfer queue
///
/// Example usage:
/// ```dart
/// // Request a file download
/// final transfer = await TransferService().requestDownload(
///   TransferRequest(
///     direction: TransferDirection.download,
///     callsign: 'X1ABCD',
///     remotePath: '/files/photos/image.jpg',
///     localPath: '/downloads/image.jpg',
///     requestingApp: 'gallery',
///   ),
/// );
///
/// // Query if file was already requested
/// final existing = TransferService().findTransfer(
///   callsign: 'X1ABCD',
///   remotePath: '/files/photos/image.jpg',
/// );
///
/// // Get progress
/// final progress = TransferService().getProgress(transferId);
/// ```
class TransferService {
  static final TransferService _instance = TransferService._internal();
  factory TransferService() => _instance;
  TransferService._internal();

  final LogService _log = LogService();
  final EventBus _eventBus = EventBus();
  final Uuid _uuid = const Uuid();

  // Components
  late final TransferStorage _storage;
  late final TransferQueue _queue;
  late final TransferWorkerPool _workerPool;
  late final TransferMetricsService _metricsService;

  // State
  bool _initialized = false;
  TransferSettings _settings = TransferSettings();
  final Map<String, Transfer> _completedCache = {};
  final Map<String, Transfer> _failedCache = {};

  // Retry timer
  Timer? _retryTimer;

  /// Stream of metrics updates
  Stream<TransferMetrics> get metricsStream => _metricsService.metricsStream;

  /// Check if initialized
  bool get isInitialized => _initialized;

  /// Initialize the service
  Future<void> initialize() async {
    if (_initialized) return;

    _log.log('TransferService: Initializing');

    // Initialize storage
    _storage = TransferStorage();
    await _storage.initialize();

    // Load settings
    _settings = await _storage.loadSettings();

    // Initialize queue
    _queue = TransferQueue(maxQueueSize: _settings.maxQueueSize);

    // Load persisted queue
    final persistedTransfers = await _storage.loadQueue();
    _queue.loadFrom(persistedTransfers);
    _log.log('TransferService: Loaded ${_queue.length} queued transfers');

    // Initialize metrics service
    _metricsService = TransferMetricsService();
    await _metricsService.initialize();

    // Initialize worker pool
    _workerPool = TransferWorkerPool(
      queue: _queue,
      maxWorkers: _settings.maxConcurrentTransfers,
    );

    _workerPool.onProgress = _handleProgress;
    _workerPool.onTransferComplete = _handleTransferComplete;

    // Start worker pool if enabled
    if (_settings.enabled) {
      await _workerPool.start();
    }

    // Start retry timer
    _startRetryTimer();

    _initialized = true;
    _log.log('TransferService: Initialized');
  }

  /// Dispose the service
  Future<void> dispose() async {
    _retryTimer?.cancel();
    await _workerPool.stop();
    await _persistQueue();
    await _metricsService.saveMetrics();
    _log.log('TransferService: Disposed');
  }

  // ========== Request Transfers ==========

  /// Request a download transfer
  Future<Transfer> requestDownload(TransferRequest request) async {
    _ensureInitialized();
    return _createTransfer(request.copyWithDirection(TransferDirection.download));
  }

  /// Request an upload transfer
  Future<Transfer> requestUpload(TransferRequest request) async {
    _ensureInitialized();
    return _createTransfer(request.copyWithDirection(TransferDirection.upload));
  }

  /// Request a stream transfer
  Future<Transfer> requestStream(TransferRequest request) async {
    _ensureInitialized();
    return _createTransfer(request.copyWithDirection(TransferDirection.stream));
  }

  /// Create a transfer from request
  Future<Transfer> _createTransfer(TransferRequest request) async {
    // Check if already requested
    final existing = findTransfer(
      callsign: request.callsign,
      remotePath: request.remotePath,
    );
    if (existing != null) {
      _log.log('TransferService: Transfer already exists: ${existing.id}');
      return existing;
    }

    // Check ban list for downloads
    if (request.direction == TransferDirection.download &&
        isCallsignBanned(request.callsign)) {
      throw Exception('Callsign ${request.callsign} is banned');
    }

    // Validate path
    if (!_isPathSafe(request.remotePath)) {
      throw Exception('Invalid path: ${request.remotePath}');
    }

    // Create transfer
    final transferId = request.id ?? 'tr_${_uuid.v4().substring(0, 8)}';
    final transfer = Transfer(
      id: transferId,
      direction: request.direction,
      sourceCallsign: request.direction == TransferDirection.upload
          ? '' // Local device is source
          : request.callsign,
      sourceStationUrl: request.stationUrl,
      targetCallsign: request.direction == TransferDirection.upload
          ? request.callsign
          : '', // Local device is target
      remotePath: request.remotePath,
      localPath: request.localPath,
      filename: path.basename(request.localPath),
      expectedBytes: request.expectedBytes ?? 0,
      expectedHash: request.expectedHash,
      timeout: request.timeout,
      status: TransferStatus.queued,
      priority: request.priority,
      requestingApp: request.requestingApp,
      metadata: request.metadata,
    );

    // Add to queue
    if (!_queue.enqueue(transfer)) {
      throw Exception('Queue is full');
    }

    await _persistQueue();

    // Fire event
    _eventBus.fire(TransferRequestedEvent(
      transferId: transfer.id,
      direction: _toEventDirection(transfer.direction),
      callsign: request.callsign,
      path: request.remotePath,
      requestingApp: request.requestingApp,
    ));

    _log.log('TransferService: Created transfer ${transfer.id}');

    // Update metrics
    _metricsService.updateQueuedCount(_queue.length);

    return transfer;
  }

  // ========== Query ==========

  /// Get transfer by ID
  Transfer? getTransfer(String transferId) {
    _ensureInitialized();

    // Check active transfers
    final active = _workerPool.activeTransfers
        .where((t) => t.id == transferId)
        .firstOrNull;
    if (active != null) return active;

    // Check queue
    final queued = _queue.getById(transferId);
    if (queued != null) return queued;

    // Check completed cache
    if (_completedCache.containsKey(transferId)) {
      return _completedCache[transferId];
    }

    // Check failed cache
    if (_failedCache.containsKey(transferId)) {
      return _failedCache[transferId];
    }

    return null;
  }

  /// Find transfer by callsign and path
  Transfer? findTransfer({
    required String callsign,
    required String remotePath,
  }) {
    _ensureInitialized();

    // Check active transfers
    for (final t in _workerPool.activeTransfers) {
      if ((t.sourceCallsign == callsign || t.targetCallsign == callsign) &&
          t.remotePath == remotePath) {
        return t;
      }
    }

    // Check queue
    for (final t in _queue.all) {
      if ((t.sourceCallsign == callsign || t.targetCallsign == callsign) &&
          t.remotePath == remotePath) {
        return t;
      }
    }

    return null;
  }

  /// Check if transfer was already requested
  bool isAlreadyRequested(String callsign, String remotePath) {
    return findTransfer(callsign: callsign, remotePath: remotePath) != null;
  }

  /// Get all active transfers
  List<Transfer> getActiveTransfers() {
    _ensureInitialized();
    return _workerPool.activeTransfers;
  }

  /// Get all queued transfers
  List<Transfer> getQueuedTransfers() {
    _ensureInitialized();
    return _queue.all;
  }

  /// Get completed transfers (from cache)
  List<Transfer> getCompletedTransfers({int limit = 50}) {
    _ensureInitialized();
    final list = _completedCache.values.toList()
      ..sort((a, b) =>
          (b.completedAt ?? b.createdAt).compareTo(a.completedAt ?? a.createdAt));
    return list.take(limit).toList();
  }

  /// Get failed transfers (from cache)
  List<Transfer> getFailedTransfers() {
    _ensureInitialized();
    return _failedCache.values.toList();
  }

  // ========== Control ==========

  /// Pause a transfer
  Future<void> pause(String transferId) async {
    _ensureInitialized();

    if (_workerPool.pauseTransfer(transferId)) {
      await _persistQueue();
      _eventBus.fire(TransferPausedEvent(transferId: transferId));
      _log.log('TransferService: Paused $transferId');
    }
  }

  /// Resume a transfer
  Future<void> resume(String transferId) async {
    _ensureInitialized();

    if (_workerPool.resumeTransfer(transferId)) {
      await _persistQueue();
      _eventBus.fire(TransferResumedEvent(transferId: transferId));
      _log.log('TransferService: Resumed $transferId');
    }
  }

  /// Cancel a transfer
  Future<void> cancel(String transferId) async {
    _ensureInitialized();

    final transfer = getTransfer(transferId);
    if (transfer != null) {
      _workerPool.cancelTransfer(transferId);
      _queue.remove(transferId);
      await _persistQueue();

      _eventBus.fire(TransferCancelledEvent(
        transferId: transferId,
        requestingApp: transfer.requestingApp,
      ));
      _log.log('TransferService: Cancelled $transferId');
    }
  }

  /// Retry a failed transfer
  Future<void> retry(String transferId) async {
    _ensureInitialized();

    final transfer = _failedCache[transferId] ?? getTransfer(transferId);
    if (transfer != null && transfer.canRetry) {
      transfer.status = TransferStatus.queued;
      transfer.error = null;
      transfer.retryCount = 0;

      _failedCache.remove(transferId);
      _queue.enqueue(transfer);
      await _persistQueue();

      _log.log('TransferService: Retry queued $transferId');
    }
  }

  /// Retry all failed transfers
  Future<void> retryAll() async {
    _ensureInitialized();

    final failed = List<Transfer>.from(_failedCache.values);
    for (final transfer in failed) {
      if (transfer.canRetry) {
        await retry(transfer.id);
      }
    }
  }

  // ========== Settings ==========

  /// Get current settings
  TransferSettings get settings => _settings;

  /// Update settings
  Future<void> updateSettings(TransferSettings newSettings) async {
    _ensureInitialized();

    _settings = newSettings;
    await _storage.saveSettings(_settings);

    // Apply settings
    _queue.maxQueueSize = _settings.maxQueueSize;
    _workerPool.maxWorkers = _settings.maxConcurrentTransfers;

    if (_settings.enabled && !_workerPool.isRunning) {
      await _workerPool.start();
    } else if (!_settings.enabled && _workerPool.isRunning) {
      await _workerPool.stop();
    }

    _log.log('TransferService: Settings updated');
  }

  // ========== Ban List ==========

  /// Ban a callsign from downloading
  Future<void> banCallsign(String callsign) async {
    _ensureInitialized();

    if (!_settings.bannedCallsigns.contains(callsign)) {
      _settings.bannedCallsigns.add(callsign);
      await _storage.saveSettings(_settings);
      _log.log('TransferService: Banned $callsign');
    }
  }

  /// Unban a callsign
  Future<void> unbanCallsign(String callsign) async {
    _ensureInitialized();

    if (_settings.bannedCallsigns.remove(callsign)) {
      await _storage.saveSettings(_settings);
      _log.log('TransferService: Unbanned $callsign');
    }
  }

  /// Check if callsign is banned
  bool isCallsignBanned(String callsign) {
    return _settings.bannedCallsigns.contains(callsign);
  }

  /// Get list of banned callsigns
  List<String> get bannedCallsigns =>
      List.unmodifiable(_settings.bannedCallsigns);

  // ========== Metrics ==========

  /// Get current metrics
  TransferMetrics getMetrics() {
    _ensureInitialized();
    return _metricsService.getMetrics();
  }

  // ========== Private Helpers ==========

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('TransferService not initialized. Call initialize() first.');
    }
  }

  void _handleProgress(Transfer transfer, int bytes, double? speed) {
    _metricsService.recordProgress(
      transfer.id,
      bytes,
      transfer.startedAt != null
          ? DateTime.now().difference(transfer.startedAt!)
          : Duration.zero,
    );
  }

  void _handleTransferComplete(Transfer transfer, bool success, String? error) {
    if (success) {
      _completedCache[transfer.id] = transfer;
      _metricsService.recordTransferComplete(transfer);

      // Archive to history
      _storage.archiveTransfer(transfer);

      // Limit cache size
      while (_completedCache.length > 100) {
        final oldest = _completedCache.values.reduce((a, b) =>
            (a.completedAt ?? a.createdAt).isBefore(b.completedAt ?? b.createdAt)
                ? a
                : b);
        _completedCache.remove(oldest.id);
      }
    } else {
      // Check if should retry
      final retryPolicy = RetryPolicy.fromSettings(_settings);

      if (retryPolicy.shouldRetry(transfer) &&
          !retryPolicy.hasExceededPatientTimeout(transfer)) {
        // Schedule retry
        transfer.retryCount++;
        final nextRetry = retryPolicy.getNextRetryTime(transfer.retryCount);
        transfer.nextRetryAt = nextRetry;
        transfer.status = TransferStatus.waiting;

        _queue.enqueue(transfer);
        _queue.scheduleRetry(transfer.id, nextRetry);

        _eventBus.fire(TransferFailedEvent(
          transferId: transfer.id,
          direction: _toEventDirection(transfer.direction),
          callsign: transfer.sourceCallsign.isNotEmpty
              ? transfer.sourceCallsign
              : transfer.targetCallsign,
          path: transfer.remotePath,
          error: error ?? 'Unknown error',
          willRetry: true,
          nextRetryAt: nextRetry,
          requestingApp: transfer.requestingApp,
        ));
      } else {
        // Final failure
        transfer.status = TransferStatus.failed;
        _failedCache[transfer.id] = transfer;
        _metricsService.recordTransferFailed(transfer);

        // Archive to history
        _storage.archiveTransfer(transfer);

        _eventBus.fire(TransferFailedEvent(
          transferId: transfer.id,
          direction: _toEventDirection(transfer.direction),
          callsign: transfer.sourceCallsign.isNotEmpty
              ? transfer.sourceCallsign
              : transfer.targetCallsign,
          path: transfer.remotePath,
          error: error ?? 'Unknown error',
          willRetry: false,
          requestingApp: transfer.requestingApp,
        ));
      }
    }

    _persistQueue();
    _metricsService.updateQueuedCount(_queue.length);
  }

  Future<void> _persistQueue() async {
    final transfers = _queue.all;
    await _storage.saveQueue(transfers);
  }

  void _startRetryTimer() {
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // The worker pool will automatically pick up ready transfers
      _metricsService.updateQueuedCount(_queue.length);
    });
  }

  bool _isPathSafe(String filePath) {
    // Prevent directory traversal
    if (filePath.contains('..')) return false;
    if (filePath.contains('//')) return false;

    // Normalize and check
    final normalized = path.normalize(filePath);
    if (normalized.startsWith('/') &&
        !normalized.startsWith('/files/') &&
        !normalized.startsWith('/chat/') &&
        !normalized.startsWith('/api/') &&
        !(normalized == '/bot/models' || normalized.startsWith('/bot/models/'))) {
      return false;
    }

    return true;
  }

  TransferEventDirection _toEventDirection(TransferDirection direction) {
    switch (direction) {
      case TransferDirection.upload:
        return TransferEventDirection.upload;
      case TransferDirection.download:
        return TransferEventDirection.download;
      case TransferDirection.stream:
        return TransferEventDirection.stream;
    }
  }
}

// Extension to add copyWithDirection to TransferRequest
extension TransferRequestExtension on TransferRequest {
  TransferRequest copyWithDirection(TransferDirection newDirection) {
    return TransferRequest(
      id: id,
      direction: newDirection,
      callsign: callsign,
      stationUrl: stationUrl,
      remotePath: remotePath,
      localPath: localPath,
      expectedBytes: expectedBytes,
      expectedHash: expectedHash,
      priority: priority,
      requestingApp: requestingApp,
      metadata: metadata,
      timeout: timeout,
    );
  }
}
