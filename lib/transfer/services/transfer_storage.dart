import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../services/log_service.dart';
import '../../services/storage_config.dart';
import '../models/transfer_metrics.dart';
import '../models/transfer_models.dart';

/// JSON file persistence for transfer queue and history
///
/// Storage location: {data_dir}/transfers/
/// Files:
/// - settings.json     - Global settings + ban list
/// - queue.json        - Active queue (persisted on changes)
/// - metrics.json      - Metrics data
/// - history/          - Completed/failed transfers by month
///   - 2026-01.json
///   - 2025-12.json
class TransferStorage {
  static final TransferStorage _instance = TransferStorage._internal();
  factory TransferStorage() => _instance;
  TransferStorage._internal();

  bool _initialized = false;
  final _log = LogService();

  /// Base directory for transfer data
  String get transfersDir => path.join(StorageConfig().baseDir, 'transfers');

  /// Settings file path
  String get settingsPath => path.join(transfersDir, 'settings.json');

  /// Queue file path
  String get queuePath => path.join(transfersDir, 'queue.json');

  /// Metrics file path
  String get metricsPath => path.join(transfersDir, 'metrics.json');

  /// History directory path
  String get historyDir => path.join(transfersDir, 'history');

  /// Initialize storage directories
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Create directories
      await Directory(transfersDir).create(recursive: true);
      await Directory(historyDir).create(recursive: true);
      _initialized = true;
      _log.log('TransferStorage initialized: $transfersDir');
    } catch (e) {
      _log.log('TransferStorage init error: $e');
      rethrow;
    }
  }

  // ========== Settings ==========

  /// Load transfer settings
  Future<TransferSettings> loadSettings() async {
    try {
      final file = File(settingsPath);
      if (!await file.exists()) {
        return TransferSettings();
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return TransferSettings.fromJson(json);
    } catch (e) {
      _log.log('TransferStorage: Error loading settings: $e');
      return TransferSettings();
    }
  }

  /// Save transfer settings
  Future<void> saveSettings(TransferSettings settings) async {
    try {
      final file = File(settingsPath);
      final json = const JsonEncoder.withIndent('  ').convert(settings.toJson());
      await file.writeAsString(json);
    } catch (e) {
      _log.log('TransferStorage: Error saving settings: $e');
      rethrow;
    }
  }

  // ========== Queue ==========

  /// Load transfer queue
  Future<List<Transfer>> loadQueue() async {
    try {
      final file = File(queuePath);
      if (!await file.exists()) {
        return [];
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final transfers = json['transfers'] as List<dynamic>? ?? [];

      return transfers
          .map((e) => Transfer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _log.log('TransferStorage: Error loading queue: $e');
      return [];
    }
  }

  /// Save transfer queue
  Future<void> saveQueue(List<Transfer> transfers) async {
    try {
      final file = File(queuePath);
      final data = {
        'version': '1.0',
        'updated_at': DateTime.now().toIso8601String(),
        'transfers': transfers.map((t) => t.toJson()).toList(),
      };
      final json = const JsonEncoder.withIndent('  ').convert(data);
      await file.writeAsString(json);
    } catch (e) {
      _log.log('TransferStorage: Error saving queue: $e');
      rethrow;
    }
  }

  // ========== History ==========

  /// Get history file path for a given month
  String _getHistoryPath(DateTime date) {
    final monthStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}.json';
    return path.join(historyDir, monthStr);
  }

  /// Archive a completed/failed transfer to history
  Future<void> archiveTransfer(Transfer transfer) async {
    try {
      final completedAt = transfer.completedAt ?? DateTime.now();
      final historyPath = _getHistoryPath(completedAt);
      final file = File(historyPath);

      List<Map<String, dynamic>> transfers = [];

      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        transfers =
            (json['transfers'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      }

      transfers.add(transfer.toJson());

      final data = {
        'version': '1.0',
        'month':
            '${completedAt.year}-${completedAt.month.toString().padLeft(2, '0')}',
        'transfers': transfers,
      };
      final json = const JsonEncoder.withIndent('  ').convert(data);
      await file.writeAsString(json);
    } catch (e) {
      _log.log('TransferStorage: Error archiving transfer: $e');
    }
  }

  /// Load history with optional limit and date filter
  Future<List<Transfer>> loadHistory({
    int limit = 100,
    DateTime? since,
  }) async {
    try {
      final historyDirectory = Directory(historyDir);
      if (!await historyDirectory.exists()) {
        return [];
      }

      final files = await historyDirectory
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();

      // Sort by filename (which is YYYY-MM.json) in descending order
      files.sort((a, b) => path.basename(b.path).compareTo(path.basename(a.path)));

      final List<Transfer> result = [];

      for (final file in files) {
        if (result.length >= limit) break;

        try {
          final content = await file.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final transfers = (json['transfers'] as List<dynamic>? ?? [])
              .map((e) => Transfer.fromJson(e as Map<String, dynamic>))
              .where((t) => since == null || t.createdAt.isAfter(since))
              .toList();

          // Sort by completed date descending
          transfers.sort((a, b) =>
              (b.completedAt ?? b.createdAt)
                  .compareTo(a.completedAt ?? a.createdAt));

          for (final transfer in transfers) {
            if (result.length >= limit) break;
            result.add(transfer);
          }
        } catch (e) {
          _log.log('TransferStorage: Error reading history file ${file.path}: $e');
        }
      }

      return result;
    } catch (e) {
      _log.log('TransferStorage: Error loading history: $e');
      return [];
    }
  }

  /// Prune old history files
  Future<void> pruneHistory({Duration maxAge = const Duration(days: 90)}) async {
    try {
      final historyDirectory = Directory(historyDir);
      if (!await historyDirectory.exists()) return;

      final cutoffDate = DateTime.now().subtract(maxAge);
      final cutoffMonth =
          '${cutoffDate.year}-${cutoffDate.month.toString().padLeft(2, '0')}';

      await for (final entity in historyDirectory.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final filename = path.basenameWithoutExtension(entity.path);
          if (filename.compareTo(cutoffMonth) < 0) {
            await entity.delete();
            _log.log('TransferStorage: Pruned old history file: ${entity.path}');
          }
        }
      }
    } catch (e) {
      _log.log('TransferStorage: Error pruning history: $e');
    }
  }

  // ========== Metrics ==========

  /// Load stored metrics
  Future<StoredMetrics> loadMetrics() async {
    try {
      final file = File(metricsPath);
      if (!await file.exists()) {
        return StoredMetrics();
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return StoredMetrics.fromJson(json);
    } catch (e) {
      _log.log('TransferStorage: Error loading metrics: $e');
      return StoredMetrics();
    }
  }

  /// Save stored metrics
  Future<void> saveMetrics(StoredMetrics metrics) async {
    try {
      final file = File(metricsPath);
      final json = const JsonEncoder.withIndent('  ').convert(metrics.toJson());
      await file.writeAsString(json);
    } catch (e) {
      _log.log('TransferStorage: Error saving metrics: $e');
      rethrow;
    }
  }

  // ========== Cleanup ==========

  /// Clear all transfer data (for testing or reset)
  Future<void> clearAll() async {
    try {
      final dir = Directory(transfersDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _initialized = false;
      await initialize();
    } catch (e) {
      _log.log('TransferStorage: Error clearing all data: $e');
      rethrow;
    }
  }

  /// Get storage stats
  Future<Map<String, dynamic>> getStorageStats() async {
    try {
      int totalSize = 0;
      int fileCount = 0;

      final dir = Directory(transfersDir);
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final stat = await entity.stat();
            totalSize += stat.size;
            fileCount++;
          }
        }
      }

      return {
        'path': transfersDir,
        'total_size_bytes': totalSize,
        'file_count': fileCount,
      };
    } catch (e) {
      _log.log('TransferStorage: Error getting storage stats: $e');
      return {
        'path': transfersDir,
        'total_size_bytes': 0,
        'file_count': 0,
        'error': e.toString(),
      };
    }
  }
}
