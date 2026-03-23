/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'storage_config.dart';
import '../version.dart';
import 'log_service.dart';

/// Service to manage crash handling and recovery on Android.
///
/// This service:
/// - Logs crashes synchronously to ensure they're written before process dies
/// - Communicates with native Android side to trigger restarts
/// - Provides access to crash logs for debugging
class CrashService {
  static final CrashService _instance = CrashService._internal();
  factory CrashService() => _instance;
  CrashService._internal();

  static const _channel = MethodChannel('dev.geogram/crash');

  File? _crashLogFile;
  bool _initialized = false;
  static const _crashFileName = 'crash.txt';

  /// Whether the crash service has been initialized
  bool get isInitialized => _initialized;

  /// Get the crash log file path
  String? get crashLogPath => _crashLogFile?.path;

  /// Initialize crash handling
  /// Call this BEFORE runApp() to catch early crashes
  Future<void> initialize() async {
    if (_initialized) return;

    // On web, we don't need file-based crash logging
    if (kIsWeb) {
      _initialized = true;
      return;
    }

    try {
      // Use StorageConfig's logsDir if available, otherwise use a fallback
      final logsDir = await _earlyLogsDir();

      final crashDir = Directory(logsDir);
      if (!await crashDir.exists()) {
        await crashDir.create(recursive: true);
      }

      _crashLogFile = File(path.join(logsDir, _crashFileName));
      _initialized = true;
    } catch (e) {
      // Can't do much here, just mark as initialized for in-memory operation
      stderr.writeln('CrashService: Failed to initialize crash log file: $e');
      _initialized = true;
    }
  }

  /// Re-initialize with proper paths after StorageConfig is ready
  Future<void> reinitialize() async {
    if (kIsWeb) return;

    final logsDir = await _resolveLogsDir();
    if (logsDir == null) return;

    final crashDir = Directory(logsDir);
    if (!await crashDir.exists()) {
      await crashDir.create(recursive: true);
    }
    _crashLogFile = File(path.join(logsDir, _crashFileName));
  }

  /// Log crash synchronously (blocking) to ensure it's written before process dies
  void logCrashSync(String type, dynamic error, StackTrace? stackTrace) {
    if (kIsWeb) {
      // On web, just print to console
      print('CRASH [$type]: $error');
      if (stackTrace != null) {
        print('Stack trace:\n$stackTrace');
      }
      return;
    }

    if (!_initialized || _crashLogFile == null) {
      stderr.writeln('CRASH [$type]: $error');
      if (stackTrace != null) {
        stderr.writeln('Stack trace:\n$stackTrace');
      }
      return;
    }

    final crashEntry = _buildCrashEntry(type, error, stackTrace);

    try {
      // Use sync write to ensure crash is logged before process dies
      _crashLogFile!.writeAsStringSync(
        crashEntry,
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      // Last resort: print to stderr
      stderr.writeln('CRASH: $crashEntry');
    }
  }

  /// Build a crash report entry
  String _buildCrashEntry(String type, dynamic error, StackTrace? stackTrace) {
    final timestamp = DateTime.now().toIso8601String();
    final buffer = StringBuffer();

    buffer.writeln('=== CRASH REPORT ===');
    buffer.writeln('Timestamp: $timestamp');
    buffer.writeln('Type: $type');
    buffer.writeln('App Version: $appVersion ($appBuildNumber)');
    buffer.writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('Error: $error');
    if (stackTrace != null) {
      buffer.writeln('Stack Trace:');
      buffer.writeln(stackTrace.toString());
    }
    buffer.writeln('=== END CRASH REPORT ===');
    buffer.writeln();

    return buffer.toString();
  }

  /// Notify native side that Flutter crashed (for restart logic)
  /// Includes stack trace and recent logs for better debugging
  Future<void> notifyNativeCrash(String error, {StackTrace? stackTrace}) async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      // Get recent log entries for context
      final recentLogs = _getRecentLogs();

      await _channel.invokeMethod('onFlutterCrash', {
        'error': error,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'stackTrace': stackTrace?.toString() ?? '',
        'appVersion': '$appVersion ($appBuildNumber)',
        'recentLogs': recentLogs,
      });
    } catch (e) {
      // Native side might already be dead, ignore
    }
  }

  /// Get recent log entries for crash context
  String _getRecentLogs() {
    try {
      final logs = LogService().messages;
      // Get last 10 log entries
      final recentLogs = logs.length > 10
          ? logs.sublist(logs.length - 10)
          : logs;
      return recentLogs.join('\n');
    } catch (e) {
      return 'Unable to retrieve logs: $e';
    }
  }

  /// Enable or disable auto-restart on crash
  Future<void> setRestartOnCrash(bool enabled) async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('setRestartOnCrash', {'enabled': enabled});
    } catch (e) {
      stderr.writeln('CrashService: Failed to set restart on crash: $e');
    }
  }

  /// Read Flutter crash logs
  Future<String?> readCrashLogs() async {
    if (kIsWeb) return null;

    try {
      final file = await _getCrashLogFile();
      if (file == null || !await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      return null;
    }
  }

  /// Read native Android crash logs
  Future<String?> readNativeCrashLogs() async {
    if (kIsWeb || !Platform.isAndroid) return null;

    try {
      final result = await _channel.invokeMethod<String?>('getCrashLogs');
      return result;
    } catch (e) {
      return null;
    }
  }

  /// Read all crash logs (Flutter + Native)
  Future<String?> readAllCrashLogs() async {
    final flutterLogs = await readCrashLogs();
    final nativeLogs = await readNativeCrashLogs();

    final parts = <String>[];
    if (flutterLogs != null && flutterLogs.isNotEmpty) {
      parts.add('=== FLUTTER CRASHES ===\n$flutterLogs');
    }
    if (nativeLogs != null && nativeLogs.isNotEmpty) {
      parts.add('=== NATIVE CRASHES ===\n$nativeLogs');
    }

    if (parts.isEmpty) return null;
    return parts.join('\n\n');
  }

  /// Remove crash reports older than [maxAgeDays] from the Flutter crash log file.
  Future<void> removeOldCrashLogs({int maxAgeDays = 5}) async {
    if (kIsWeb) return;

    try {
      final file = await _getCrashLogFile();
      if (file == null || !await file.exists()) return;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return;

      const startMarker = '=== CRASH REPORT ===';
      const endMarker = '=== END CRASH REPORT ===';
      final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));
      final kept = StringBuffer();

      int searchStart = 0;
      while (true) {
        final startIndex = content.indexOf(startMarker, searchStart);
        if (startIndex == -1) break;

        final endIndex = content.indexOf(endMarker, startIndex);
        final String block;
        if (endIndex == -1) {
          block = content.substring(startIndex).trim();
          searchStart = content.length;
        } else {
          block = content.substring(startIndex, endIndex + endMarker.length).trim();
          searchStart = endIndex + endMarker.length;
        }

        // Extract timestamp from block
        DateTime? ts;
        for (final line in block.split('\n')) {
          if (line.startsWith('Timestamp: ')) {
            try {
              ts = DateTime.parse(line.substring('Timestamp: '.length).trim());
            } catch (_) {}
            break;
          }
        }

        // Keep if timestamp is missing (can't determine age) or within cutoff
        if (ts == null || ts.isAfter(cutoff)) {
          kept.writeln(block);
          kept.writeln();
        }
      }

      final result = kept.toString().trim();
      if (result.isEmpty) {
        await file.delete();
      } else {
        await file.writeAsString('$result\n');
      }
    } catch (_) {
      // Best-effort cleanup, don't fail loudly
    }
  }

  /// Clear Flutter crash logs
  Future<void> clearCrashLogs() async {
    if (kIsWeb) return;

    try {
      await LogService().clearCrashLog();
    } catch (_) {}

    final file = await _getCrashLogFile();
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }

  /// Clear native Android crash logs
  Future<void> clearNativeCrashLogs() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('clearNativeCrashLogs');
    } catch (e) {
      // Ignore
    }
  }

  /// Clear all crash logs
  Future<void> clearAllCrashLogs() async {
    await clearCrashLogs();
    await clearNativeCrashLogs();
  }

  /// Check if there are any crash logs from a previous session
  Future<bool> hasCrashLogs() async {
    final flutterLogs = await readCrashLogs();
    if (flutterLogs != null && flutterLogs.isNotEmpty) return true;

    final nativeLogs = await readNativeCrashLogs();
    if (nativeLogs != null && nativeLogs.isNotEmpty) return true;

    return false;
  }

  /// Check if the app just recovered from a crash
  Future<bool> didRecoverFromCrash() async {
    if (kIsWeb || !Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('didRecoverFromCrash');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Clear the crash recovery flag
  Future<void> clearRecoveredFromCrash() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('clearRecoveredFromCrash');
    } catch (e) {
      // Ignore
    }
  }

  Future<String> _earlyLogsDir() async {
    if (StorageConfig().isInitialized) {
      return StorageConfig().logsDir;
    }
    return path.join(Directory.systemTemp.path, 'geogram', 'logs');
  }

  Future<String?> _resolveLogsDir() async {
    try {
      if (StorageConfig().isInitialized) {
        return StorageConfig().logsDir;
      }
      // Fallback to system temp (same as _earlyLogsDir) — never write to Documents
      return path.join(Directory.systemTemp.path, 'geogram', 'logs');
    } catch (_) {
      return null;
    }
  }

  Future<File?> _getCrashLogFile() async {
    if (kIsWeb) return null;
    if (_crashLogFile != null) return _crashLogFile;

    final logsDir = await _resolveLogsDir();
    if (logsDir == null) return null;

    final crashDir = Directory(logsDir);
    if (!await crashDir.exists()) {
      await crashDir.create(recursive: true);
    }

    _crashLogFile = File(path.join(logsDir, _crashFileName));
    return _crashLogFile;
  }
}
