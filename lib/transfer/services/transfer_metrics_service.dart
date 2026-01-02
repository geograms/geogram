import 'dart:async';

import '../../services/log_service.dart';
import '../models/transfer_metrics.dart';
import '../models/transfer_models.dart';
import 'transfer_storage.dart';

/// Service for tracking and managing transfer metrics
///
/// Features:
/// - Real-time tracking of active transfers
/// - Historical statistics by period (today, week, month, all-time)
/// - Per-transport breakdown
/// - Per-callsign statistics
/// - Hourly history for charts
class TransferMetricsService {
  static final TransferMetricsService _instance =
      TransferMetricsService._internal();
  factory TransferMetricsService() => _instance;
  TransferMetricsService._internal();

  final LogService _log = LogService();
  final TransferStorage _storage = TransferStorage();

  bool _initialized = false;
  StoredMetrics _storedMetrics = StoredMetrics();

  // Real-time tracking
  int _activeConnections = 0;
  int _activeTransfers = 0;
  int _queuedTransfers = 0;
  double _currentSpeed = 0;
  final Map<String, double> _transferSpeeds = {};

  // Stream controllers
  final _metricsController = StreamController<TransferMetrics>.broadcast();
  final _speedController = StreamController<double>.broadcast();
  final _connectionCountController = StreamController<int>.broadcast();

  // Debounce save
  Timer? _saveTimer;
  bool _dirty = false;

  /// Stream of metrics updates
  Stream<TransferMetrics> get metricsStream => _metricsController.stream;

  /// Stream of current speed updates
  Stream<double> get speedStream => _speedController.stream;

  /// Stream of connection count updates
  Stream<int> get connectionCountStream => _connectionCountController.stream;

  /// Initialize the service
  Future<void> initialize() async {
    if (_initialized) return;

    await _storage.initialize();
    _storedMetrics = await _storage.loadMetrics();
    _initialized = true;
    _log.log('TransferMetricsService initialized');
  }

  /// Get current metrics snapshot
  TransferMetrics getMetrics() {
    final now = DateTime.now();
    final todayKey = _dateKey(now);
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final monthStart = DateTime(now.year, now.month, 1);

    // Calculate period stats
    TransferPeriodStats todayStats = const TransferPeriodStats();
    TransferPeriodStats weekStats = const TransferPeriodStats();
    TransferPeriodStats monthStats = const TransferPeriodStats();

    for (final entry in _storedMetrics.daily.entries) {
      final date = DateTime.tryParse(entry.key);
      if (date != null) {
        if (entry.key == todayKey) {
          todayStats = entry.value.stats;
        }
        if (date.isAfter(weekStart.subtract(const Duration(days: 1)))) {
          weekStats = weekStats + entry.value.stats;
        }
        if (date.isAfter(monthStart.subtract(const Duration(days: 1)))) {
          monthStats = monthStats + entry.value.stats;
        }
      }
    }

    // Get top callsigns (sorted by total bytes)
    final callsignList = _storedMetrics.byCallsign.values.toList()
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    final topCallsigns = callsignList.take(10).toList();

    return TransferMetrics(
      activeConnections: _activeConnections,
      activeTransfers: _activeTransfers,
      queuedTransfers: _queuedTransfers,
      currentSpeedBytesPerSecond: _currentSpeed,
      today: todayStats,
      thisWeek: weekStats,
      thisMonth: monthStats,
      allTime: _storedMetrics.allTime,
      byTransport: _storedMetrics.byTransport,
      topCallsigns: topCallsigns,
    );
  }

  /// Record transfer start
  void recordTransferStart(Transfer transfer) {
    _activeTransfers++;
    _emitMetrics();

    // Record first transfer if needed
    if (_storedMetrics.firstTransferAt == null) {
      _storedMetrics = StoredMetrics(
        allTime: _storedMetrics.allTime,
        firstTransferAt: DateTime.now(),
        daily: _storedMetrics.daily,
        byCallsign: _storedMetrics.byCallsign,
        byTransport: _storedMetrics.byTransport,
      );
      _markDirty();
    }
  }

  /// Record transfer progress
  void recordProgress(String transferId, int bytes, Duration elapsed) {
    if (elapsed.inMilliseconds > 0) {
      final speed = bytes / (elapsed.inMilliseconds / 1000);
      _transferSpeeds[transferId] = speed;
      _updateCurrentSpeed();
    }
  }

  /// Record transfer completion
  void recordTransferComplete(Transfer transfer) {
    _activeTransfers = (_activeTransfers - 1).clamp(0, 1000000);
    _transferSpeeds.remove(transfer.id);
    _updateCurrentSpeed();

    // Update stats
    _updateStats(transfer, success: true);
    _emitMetrics();
  }

  /// Record transfer failure
  void recordTransferFailed(Transfer transfer) {
    _activeTransfers = (_activeTransfers - 1).clamp(0, 1000000);
    _transferSpeeds.remove(transfer.id);
    _updateCurrentSpeed();

    // Update stats
    _updateStats(transfer, success: false);
    _emitMetrics();
  }

  /// Record connection opened
  void recordConnectionOpened(String callsign, String transport) {
    _activeConnections++;
    _connectionCountController.add(_activeConnections);
    _emitMetrics();
  }

  /// Record connection closed
  void recordConnectionClosed(String callsign, String transport) {
    _activeConnections = (_activeConnections - 1).clamp(0, 1000000);
    _connectionCountController.add(_activeConnections);
    _emitMetrics();
  }

  /// Update queued transfer count
  void updateQueuedCount(int count) {
    _queuedTransfers = count;
    _emitMetrics();
  }

  /// Get stats for a specific period
  TransferPeriodStats getStatsForPeriod(DateTime start, DateTime end) {
    TransferPeriodStats stats = const TransferPeriodStats();

    for (final entry in _storedMetrics.daily.entries) {
      final date = DateTime.tryParse(entry.key);
      if (date != null &&
          date.isAfter(start.subtract(const Duration(days: 1))) &&
          date.isBefore(end.add(const Duration(days: 1)))) {
        stats = stats + entry.value.stats;
      }
    }

    return stats;
  }

  /// Get history for charts
  List<TransferHistoryPoint> getHistory({
    required Duration period,
    required Duration resolution,
  }) {
    final now = DateTime.now();
    final start = now.subtract(period);
    final List<TransferHistoryPoint> points = [];

    // For daily resolution
    if (resolution.inHours >= 24) {
      DateTime current = start;
      while (current.isBefore(now)) {
        final key = _dateKey(current);
        final daily = _storedMetrics.daily[key];
        points.add(TransferHistoryPoint(
          timestamp: current,
          bytesTransferred: daily?.stats.totalBytes ?? 0,
          activeConnections: 0,
        ));
        current = current.add(const Duration(days: 1));
      }
    }
    // For hourly resolution
    else {
      final todayKey = _dateKey(now);
      final daily = _storedMetrics.daily[todayKey];
      if (daily != null) {
        for (final hourly in daily.hourly) {
          final timestamp = DateTime(now.year, now.month, now.day, hourly.hour);
          if (timestamp.isAfter(start)) {
            points.add(TransferHistoryPoint(
              timestamp: timestamp,
              bytesTransferred: hourly.bytesTransferred,
              activeConnections: hourly.connections,
            ));
          }
        }
      }
    }

    return points;
  }

  /// Save metrics to storage
  Future<void> saveMetrics() async {
    if (!_initialized) return;
    await _storage.saveMetrics(_storedMetrics);
    _dirty = false;
    _log.log('TransferMetricsService: Metrics saved');
  }

  /// Prune old history data
  Future<void> pruneOldHistory({Duration maxAge = const Duration(days: 90)}) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final cutoffKey = _dateKey(cutoff);

    final newDaily = Map<String, DailyStats>.from(_storedMetrics.daily);
    newDaily.removeWhere((key, _) => key.compareTo(cutoffKey) < 0);

    _storedMetrics = StoredMetrics(
      allTime: _storedMetrics.allTime,
      firstTransferAt: _storedMetrics.firstTransferAt,
      daily: newDaily,
      byCallsign: _storedMetrics.byCallsign,
      byTransport: _storedMetrics.byTransport,
    );

    await saveMetrics();
    _log.log('TransferMetricsService: Pruned history older than $maxAge');
  }

  // Private helpers

  void _updateStats(Transfer transfer, {required bool success}) {
    final now = DateTime.now();
    final todayKey = _dateKey(now);
    final hour = now.hour;

    // Get or create daily stats
    final daily = _storedMetrics.daily[todayKey] ?? DailyStats(date: todayKey);
    final hourlyList = List<HourlyStats>.from(daily.hourly);

    // Update or add hourly stats
    final hourlyIndex = hourlyList.indexWhere((h) => h.hour == hour);
    HourlyStats hourly;
    if (hourlyIndex >= 0) {
      hourly = hourlyList[hourlyIndex];
      hourlyList[hourlyIndex] = HourlyStats(
        hour: hour,
        bytesTransferred: hourly.bytesTransferred + transfer.bytesTransferred,
        connections: hourly.connections,
        transfers: hourly.transfers + 1,
      );
    } else {
      hourlyList.add(HourlyStats(
        hour: hour,
        bytesTransferred: transfer.bytesTransferred,
        connections: _activeConnections,
        transfers: 1,
      ));
    }

    // Calculate new daily stats
    final direction = transfer.direction;
    final newDailyStats = TransferPeriodStats(
      uploadCount: daily.stats.uploadCount +
          (direction == TransferDirection.upload ? 1 : 0),
      downloadCount: daily.stats.downloadCount +
          (direction == TransferDirection.download ? 1 : 0),
      streamCount: daily.stats.streamCount +
          (direction == TransferDirection.stream ? 1 : 0),
      bytesUploaded: daily.stats.bytesUploaded +
          (direction == TransferDirection.upload ? transfer.bytesTransferred : 0),
      bytesDownloaded: daily.stats.bytesDownloaded +
          (direction == TransferDirection.download ? transfer.bytesTransferred : 0),
      failedCount: daily.stats.failedCount + (success ? 0 : 1),
      totalTransferTime: daily.stats.totalTransferTime +
          (transfer.completedAt != null && transfer.startedAt != null
              ? transfer.completedAt!.difference(transfer.startedAt!)
              : Duration.zero),
    );

    final newDaily = Map<String, DailyStats>.from(_storedMetrics.daily);
    newDaily[todayKey] = DailyStats(
      date: todayKey,
      stats: newDailyStats,
      hourly: hourlyList,
    );

    // Update all-time stats
    final newAllTime = TransferPeriodStats(
      uploadCount: _storedMetrics.allTime.uploadCount +
          (direction == TransferDirection.upload ? 1 : 0),
      downloadCount: _storedMetrics.allTime.downloadCount +
          (direction == TransferDirection.download ? 1 : 0),
      streamCount: _storedMetrics.allTime.streamCount +
          (direction == TransferDirection.stream ? 1 : 0),
      bytesUploaded: _storedMetrics.allTime.bytesUploaded +
          (direction == TransferDirection.upload ? transfer.bytesTransferred : 0),
      bytesDownloaded: _storedMetrics.allTime.bytesDownloaded +
          (direction == TransferDirection.download ? transfer.bytesTransferred : 0),
      failedCount: _storedMetrics.allTime.failedCount + (success ? 0 : 1),
    );

    // Update callsign stats
    final callsign = direction == TransferDirection.upload
        ? transfer.targetCallsign
        : transfer.sourceCallsign;
    final callsignStats = _storedMetrics.byCallsign[callsign] ??
        CallsignStats(callsign: callsign);
    final newCallsignStats = CallsignStats(
      callsign: callsign,
      uploadCount: callsignStats.uploadCount +
          (direction == TransferDirection.upload ? 1 : 0),
      downloadCount: callsignStats.downloadCount +
          (direction == TransferDirection.download ? 1 : 0),
      bytesUploaded: callsignStats.bytesUploaded +
          (direction == TransferDirection.upload ? transfer.bytesTransferred : 0),
      bytesDownloaded: callsignStats.bytesDownloaded +
          (direction == TransferDirection.download ? transfer.bytesTransferred : 0),
      lastActivity: now,
    );
    final newByCallsign = Map<String, CallsignStats>.from(_storedMetrics.byCallsign);
    newByCallsign[callsign] = newCallsignStats;

    // Update transport stats
    final transportId = transfer.transportUsed ?? 'unknown';
    final transportStats = _storedMetrics.byTransport[transportId] ??
        TransportStats(transportId: transportId);
    final totalCount = transportStats.transferCount + 1;
    final successCount = success
        ? (transportStats.transferCount * transportStats.successRate).round() + 1
        : (transportStats.transferCount * transportStats.successRate).round();
    final newTransportStats = TransportStats(
      transportId: transportId,
      transferCount: totalCount,
      bytesTransferred:
          transportStats.bytesTransferred + transfer.bytesTransferred,
      averageSpeed: transfer.speedBytesPerSecond ?? transportStats.averageSpeed,
      successRate: totalCount > 0 ? successCount / totalCount : 1.0,
    );
    final newByTransport = Map<String, TransportStats>.from(_storedMetrics.byTransport);
    newByTransport[transportId] = newTransportStats;

    // Save updated metrics
    _storedMetrics = StoredMetrics(
      allTime: newAllTime,
      firstTransferAt: _storedMetrics.firstTransferAt,
      daily: newDaily,
      byCallsign: newByCallsign,
      byTransport: newByTransport,
    );

    _markDirty();
  }

  void _updateCurrentSpeed() {
    if (_transferSpeeds.isEmpty) {
      _currentSpeed = 0;
    } else {
      _currentSpeed = _transferSpeeds.values.reduce((a, b) => a + b);
    }
    _speedController.add(_currentSpeed);
  }

  void _emitMetrics() {
    _metricsController.add(getMetrics());
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), () {
      if (_dirty) {
        saveMetrics();
      }
    });
  }

  String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// Dispose resources
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) {
      saveMetrics();
    }
    _metricsController.close();
    _speedController.close();
    _connectionCountController.close();
  }
}
