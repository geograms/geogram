import 'dart:async';

import '../../services/log_service.dart';
import '../models/transfer_models.dart';
import 'transfer_queue.dart';
import 'transfer_worker.dart';

/// Callback when a transfer completes or fails
typedef PoolTransferCompleteCallback = void Function(
  Transfer transfer,
  bool success,
  String? error,
);

/// Manages concurrent transfer workers
///
/// Spawns up to maxWorkers workers that:
/// - Pull from the queue
/// - Execute transfers via ConnectionManager
/// - Report progress
/// - Handle retries
class TransferWorkerPool {
  final TransferQueue queue;
  final LogService _log = LogService();

  final List<TransferWorker> _workers = [];
  final Map<String, Transfer> _activeTransfers = {};

  int _maxWorkers;
  bool _running = false;
  Timer? _pollTimer;

  /// Callback when a transfer completes or fails
  PoolTransferCompleteCallback? onTransferComplete;

  /// Callback for progress updates
  TransferProgressCallback? onProgress;

  TransferWorkerPool({
    required this.queue,
    int maxWorkers = 3,
  }) : _maxWorkers = maxWorkers;

  /// Get/set max concurrent workers
  int get maxWorkers => _maxWorkers;
  set maxWorkers(int value) {
    _maxWorkers = value;
    _adjustWorkerCount();
  }

  /// Check if pool is running
  bool get isRunning => _running;

  /// Get number of active workers
  int get activeWorkerCount => _workers.where((w) => w.isBusy).length;

  /// Get number of idle workers
  int get idleWorkerCount => _workers.where((w) => !w.isBusy).length;

  /// Get list of active transfers
  List<Transfer> get activeTransfers => _activeTransfers.values.toList();

  /// Start the worker pool
  Future<void> start() async {
    if (_running) return;

    _running = true;
    _log.log('TransferWorkerPool: Starting with $_maxWorkers max workers');

    // Create initial workers
    for (int i = 0; i < _maxWorkers; i++) {
      _createWorker();
    }

    // Start polling for work
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _assignWork();
    });

    // Initial assignment
    _assignWork();
  }

  /// Stop the worker pool
  Future<void> stop() async {
    if (!_running) return;

    _running = false;
    _log.log('TransferWorkerPool: Stopping');

    _pollTimer?.cancel();
    _pollTimer = null;

    // Cancel all active transfers
    for (final worker in _workers) {
      if (worker.isBusy) {
        worker.cancel();
      }
    }

    _workers.clear();
    _activeTransfers.clear();
  }

  /// Adjust worker count
  void _adjustWorkerCount() {
    // Remove excess idle workers
    while (_workers.length > _maxWorkers) {
      final idleWorker = _workers.firstWhere(
        (w) => !w.isBusy,
        orElse: () => null as TransferWorker,
      );
      if (idleWorker != null) {
        _workers.remove(idleWorker);
      } else {
        break; // All workers are busy
      }
    }

    // Add workers if needed
    while (_workers.length < _maxWorkers) {
      _createWorker();
    }
  }

  /// Create a new worker
  void _createWorker() {
    final workerId = 'worker_${_workers.length + 1}';
    final worker = TransferWorker(workerId: workerId);

    worker.onProgress = (transfer, bytes, speed) {
      _activeTransfers[transfer.id] = transfer;
      onProgress?.call(transfer, bytes, speed);
    };

    worker.onComplete = (transfer, success, error) {
      _activeTransfers.remove(transfer.id);
      onTransferComplete?.call(transfer, success, error);

      // Try to assign more work
      if (_running) {
        _assignWork();
      }
    };

    _workers.add(worker);
  }

  /// Assign work to idle workers
  void _assignWork() {
    if (!_running) return;

    for (final worker in _workers) {
      if (!worker.isBusy) {
        final transfer = queue.dequeueReady();
        if (transfer != null) {
          _activeTransfers[transfer.id] = transfer;
          _log.log('TransferWorkerPool: Assigning ${transfer.id} to ${worker.workerId}');

          // Start processing in background
          worker.processTransfer(transfer).catchError((e) {
            _log.log('TransferWorkerPool: Error in ${worker.workerId}: $e');
          });
        }
      }
    }
  }

  /// Cancel a specific transfer
  bool cancelTransfer(String transferId) {
    // Check if transfer is active
    if (_activeTransfers.containsKey(transferId)) {
      for (final worker in _workers) {
        if (worker.currentTransfer?.id == transferId) {
          worker.cancel();
          return true;
        }
      }
    }

    // Check if transfer is in queue
    return queue.remove(transferId);
  }

  /// Pause a transfer (remove from active, return to queue with paused status)
  bool pauseTransfer(String transferId) {
    final transfer = _activeTransfers[transferId];
    if (transfer != null) {
      // Cancel active transfer
      for (final worker in _workers) {
        if (worker.currentTransfer?.id == transferId) {
          worker.cancel();
        }
      }

      // Update status and re-queue
      transfer.status = TransferStatus.paused;
      queue.enqueue(transfer);
      return true;
    }

    // Already in queue, just update status
    final queued = queue.getById(transferId);
    if (queued != null) {
      queued.status = TransferStatus.paused;
      return true;
    }

    return false;
  }

  /// Resume a paused transfer
  bool resumeTransfer(String transferId) {
    final transfer = queue.getById(transferId);
    if (transfer != null && transfer.status == TransferStatus.paused) {
      transfer.status = TransferStatus.queued;
      queue.update(transfer);
      _assignWork();
      return true;
    }
    return false;
  }

  /// Get pool statistics
  Map<String, dynamic> get stats => {
        'running': _running,
        'max_workers': _maxWorkers,
        'total_workers': _workers.length,
        'active_workers': activeWorkerCount,
        'idle_workers': idleWorkerCount,
        'active_transfers': _activeTransfers.length,
        'queued_transfers': queue.length,
      };
}
