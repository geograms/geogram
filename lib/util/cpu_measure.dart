/// Cross-platform CPU + memory snapshot for profiling.
///
/// Linux/Android: reads /proc/self/stat for real CPU time (user+system).
/// macOS/Windows/iOS: falls back to Stopwatch (wall-clock).
/// Memory: ProcessInfo.currentRss on all platforms.
library;

import 'dart:io';

/// A snapshot of process CPU time and memory at a point in time.
class CpuSnapshot {
  /// Total process CPU time in milliseconds (user + system).
  /// On Linux/Android this is real CPU time from /proc/self/stat.
  /// On other platforms this is wall-clock from a shared Stopwatch.
  final int cpuMs;

  /// Resident set size in bytes.
  final int rssBytes;

  /// Wall-clock timestamp for delta calculation.
  final int _wallUs;

  CpuSnapshot._(this.cpuMs, this.rssBytes, this._wallUs);

  /// Take a snapshot now.
  static CpuSnapshot now() {
    final rss = ProcessInfo.currentRss;
    final wallUs = _stopwatch.elapsedMicroseconds;

    if (Platform.isLinux || Platform.isAndroid) {
      final cpuMs = _readProcCpu();
      if (cpuMs != null) {
        return CpuSnapshot._(cpuMs, rss, wallUs);
      }
    }

    // Fallback: wall-clock
    return CpuSnapshot._(wallUs ~/ 1000, rss, wallUs);
  }

  /// Compute the delta between this snapshot and a previous one.
  CpuDelta delta(CpuSnapshot before) {
    return CpuDelta(
      cpuMs: cpuMs - before.cpuMs,
      wallMs: (_wallUs - before._wallUs) ~/ 1000,
      rssDeltaBytes: rssBytes - before.rssBytes,
      rssBytes: rssBytes,
    );
  }

  /// Shared stopwatch for wall-clock fallback.
  static final _stopwatch = Stopwatch()..start();

  /// Read CPU time from /proc/self/stat (Linux/Android).
  /// Returns total user+system CPU in milliseconds, or null on failure.
  static int? _readProcCpu() {
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      final fields = stat.split(' ');
      if (fields.length < 15) return null;
      final utime = int.parse(fields[13]);
      final stime = int.parse(fields[14]);
      // Clock ticks per second is 100 on standard Linux
      return ((utime + stime) * 1000) ~/ 100;
    } catch (_) {
      return null;
    }
  }
}

/// Delta between two CpuSnapshots.
class CpuDelta {
  /// CPU time consumed in milliseconds.
  final int cpuMs;

  /// Wall-clock time in milliseconds.
  final int wallMs;

  /// Change in RSS (can be negative if memory freed).
  final int rssDeltaBytes;

  /// Current RSS after the operation.
  final int rssBytes;

  CpuDelta({
    required this.cpuMs,
    required this.wallMs,
    required this.rssDeltaBytes,
    required this.rssBytes,
  });

  /// RSS delta in megabytes (signed).
  String get rssDeltaMB {
    final mb = rssDeltaBytes / 1024 / 1024;
    return '${mb >= 0 ? "+" : ""}${mb.toStringAsFixed(1)}MB';
  }

  /// Current RSS in megabytes.
  String get rssMB => '${(rssBytes / 1024 / 1024).toStringAsFixed(1)}MB';

  @override
  String toString() => '${cpuMs}ms cpu, ${wallMs}ms wall, $rssDeltaMB';
}
