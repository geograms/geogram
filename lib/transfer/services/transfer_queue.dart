import 'dart:async';
import 'dart:collection';

import '../models/transfer_models.dart';

/// Manages the transfer queue with priority ordering
///
/// Queue ordering:
/// 1. Priority (urgent > high > normal > low)
/// 2. Creation time (FIFO within same priority)
///
/// Features:
/// - Max queue size enforcement
/// - Automatic retry scheduling
/// - Query by various criteria
class TransferQueue {
  final Map<String, Transfer> _byId = {};
  final SplayTreeSet<Transfer> _priorityQueue = SplayTreeSet<Transfer>(_compareTransfers);
  final Map<String, DateTime> _retrySchedule = {};

  int maxQueueSize;

  TransferQueue({this.maxQueueSize = 1000});

  /// Compare transfers for priority ordering
  /// Priority: urgent(0) > high(1) > normal(2) > low(3)
  /// Within same priority: older first (FIFO)
  static int _compareTransfers(Transfer a, Transfer b) {
    // First compare by priority (lower index = higher priority)
    final priorityCompare = a.priority.index.compareTo(b.priority.index);
    if (priorityCompare != 0) return priorityCompare;

    // Then by creation time (older first)
    final timeCompare = a.createdAt.compareTo(b.createdAt);
    if (timeCompare != 0) return timeCompare;

    // Finally by ID for stable ordering
    return a.id.compareTo(b.id);
  }

  /// Add a transfer to the queue
  /// Returns false if queue is full
  bool enqueue(Transfer transfer) {
    if (_byId.length >= maxQueueSize) {
      return false;
    }

    // Remove existing if present (for re-queue)
    if (_byId.containsKey(transfer.id)) {
      _priorityQueue.remove(_byId[transfer.id]);
    }

    _byId[transfer.id] = transfer;
    _priorityQueue.add(transfer);
    return true;
  }

  /// Remove and return the highest priority transfer
  Transfer? dequeue() {
    if (_priorityQueue.isEmpty) return null;

    final transfer = _priorityQueue.first;
    _priorityQueue.remove(transfer);
    _byId.remove(transfer.id);
    _retrySchedule.remove(transfer.id);
    return transfer;
  }

  /// Get the highest priority transfer without removing
  Transfer? peek() {
    if (_priorityQueue.isEmpty) return null;
    return _priorityQueue.first;
  }

  /// Get next transfer that's ready (not scheduled for later)
  Transfer? dequeueReady() {
    final now = DateTime.now();

    for (final transfer in _priorityQueue) {
      final scheduledAt = _retrySchedule[transfer.id];
      if (scheduledAt == null || scheduledAt.isBefore(now)) {
        _priorityQueue.remove(transfer);
        _byId.remove(transfer.id);
        _retrySchedule.remove(transfer.id);
        return transfer;
      }
    }

    return null;
  }

  /// Remove a transfer by ID
  bool remove(String transferId) {
    final transfer = _byId[transferId];
    if (transfer != null) {
      _priorityQueue.remove(transfer);
      _byId.remove(transferId);
      _retrySchedule.remove(transferId);
      return true;
    }
    return false;
  }

  /// Update a transfer in the queue
  void update(Transfer transfer) {
    final existing = _byId[transfer.id];
    if (existing != null) {
      _priorityQueue.remove(existing);
    }
    _byId[transfer.id] = transfer;
    _priorityQueue.add(transfer);
  }

  /// Update transfer priority
  void updatePriority(String transferId, TransferPriority priority) {
    final transfer = _byId[transferId];
    if (transfer != null) {
      _priorityQueue.remove(transfer);
      transfer.priority = priority;
      _priorityQueue.add(transfer);
    }
  }

  /// Schedule retry for a transfer
  void scheduleRetry(String transferId, DateTime retryAt) {
    _retrySchedule[transferId] = retryAt;
  }

  /// Get scheduled retry time for a transfer
  DateTime? getScheduledRetry(String transferId) => _retrySchedule[transferId];

  /// Get transfer by ID
  Transfer? getById(String transferId) => _byId[transferId];

  /// Check if transfer exists
  bool contains(String transferId) => _byId.containsKey(transferId);

  /// Find transfer by callsign and path
  Transfer? findByPath(String callsign, String remotePath) {
    return _byId.values.firstWhere(
      (t) =>
          (t.sourceCallsign == callsign || t.targetCallsign == callsign) &&
          t.remotePath == remotePath,
      orElse: () => null as Transfer,
    );
  }

  /// Get all transfers matching a filter
  List<Transfer> where(bool Function(Transfer) test) {
    return _byId.values.where(test).toList();
  }

  /// Get all queued transfers
  List<Transfer> get queued =>
      where((t) => t.status == TransferStatus.queued);

  /// Get all waiting transfers (patient mode)
  List<Transfer> get waiting =>
      where((t) => t.status == TransferStatus.waiting);

  /// Get all scheduled retries
  Map<String, DateTime> get scheduledRetries => Map.unmodifiable(_retrySchedule);

  /// Get time until next scheduled retry
  Duration? get timeUntilNextRetry {
    if (_retrySchedule.isEmpty) return null;

    final now = DateTime.now();
    DateTime? earliest;

    for (final scheduledAt in _retrySchedule.values) {
      if (scheduledAt.isAfter(now)) {
        if (earliest == null || scheduledAt.isBefore(earliest)) {
          earliest = scheduledAt;
        }
      }
    }

    return earliest?.difference(now);
  }

  /// Get number of transfers in queue
  int get length => _byId.length;

  /// Check if queue is empty
  bool get isEmpty => _byId.isEmpty;

  /// Check if queue is full
  bool get isFull => _byId.length >= maxQueueSize;

  /// Get all transfers as a list (ordered by priority)
  List<Transfer> toList() => _priorityQueue.toList();

  /// Get all transfers as a list (unordered, faster)
  List<Transfer> get all => _byId.values.toList();

  /// Clear all transfers
  void clear() {
    _byId.clear();
    _priorityQueue.clear();
    _retrySchedule.clear();
  }

  /// Load transfers from list (e.g., from storage)
  void loadFrom(List<Transfer> transfers) {
    clear();
    for (final transfer in transfers) {
      if (transfer.status == TransferStatus.queued ||
          transfer.status == TransferStatus.waiting ||
          transfer.status == TransferStatus.paused) {
        enqueue(transfer);
      }
    }
  }

  /// Get queue statistics
  Map<String, int> get stats {
    int queued = 0;
    int waiting = 0;
    int paused = 0;
    int scheduled = 0;

    for (final transfer in _byId.values) {
      switch (transfer.status) {
        case TransferStatus.queued:
          queued++;
          break;
        case TransferStatus.waiting:
          waiting++;
          break;
        case TransferStatus.paused:
          paused++;
          break;
        default:
          break;
      }
    }

    final now = DateTime.now();
    for (final scheduledAt in _retrySchedule.values) {
      if (scheduledAt.isAfter(now)) scheduled++;
    }

    return {
      'total': _byId.length,
      'queued': queued,
      'waiting': waiting,
      'paused': paused,
      'scheduled': scheduled,
    };
  }
}
