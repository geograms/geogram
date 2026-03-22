/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Priority level for monitored tasks.
enum TaskPriority {
  critical,
  normal,
  low,
}

/// Type of background task.
enum TaskType {
  periodic,
  isolate,
  oneshot,
}

/// Runtime status of a monitored task.
enum TaskStatus {
  idle,
  running,
  paused,
  error,
}

/// A background task registered with [TaskMonitorService].
class MonitoredTask {
  /// Compound identifier: `serviceName.taskName`
  final String id;

  /// Human-readable name
  final String name;

  /// What this task does (mutable for progress updates)
  String description;

  /// Owning service name
  final String serviceName;

  /// Priority level
  final TaskPriority priority;

  /// Execution pattern
  final TaskType type;

  /// Repeat interval (null for oneshot / isolate)
  final Duration? interval;

  // --- Runtime state (mutable) ---

  TaskStatus status;
  DateTime? lastRunAt;
  Duration? lastDuration;
  int runCount;
  int successCount;
  int failCount;
  String? lastError;
  final DateTime registeredAt;

  // --- CPU profiling (mutable) ---

  /// Cumulative real CPU time across all runs (ms).
  int totalCpuMs;

  /// One-shot init CPU time (ms). Set for TaskType.oneshot.
  int initCpuMs;

  /// One-shot init wall-clock time (ms).
  int initWallMs;

  /// RSS change during init (bytes, can be negative).
  int rssDeltaBytes;

  MonitoredTask({
    required this.id,
    required this.name,
    required this.description,
    required this.serviceName,
    required this.priority,
    required this.type,
    this.interval,
    this.status = TaskStatus.idle,
    this.lastRunAt,
    this.lastDuration,
    this.runCount = 0,
    this.successCount = 0,
    this.failCount = 0,
    this.lastError,
    this.totalCpuMs = 0,
    this.initCpuMs = 0,
    this.initWallMs = 0,
    this.rssDeltaBytes = 0,
    DateTime? registeredAt,
  }) : registeredAt = registeredAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'serviceName': serviceName,
        'priority': priority.name,
        'type': type.name,
        'intervalMs': interval?.inMilliseconds,
        'status': status.name,
        'lastRunAt': lastRunAt?.toIso8601String(),
        'lastDurationMs': lastDuration?.inMilliseconds,
        'runCount': runCount,
        'successCount': successCount,
        'failCount': failCount,
        'lastError': lastError,
        'totalCpuMs': totalCpuMs,
        'initCpuMs': initCpuMs,
        'initWallMs': initWallMs,
        'rssDeltaBytes': rssDeltaBytes,
        'registeredAt': registeredAt.toIso8601String(),
      };
}

/// Event emitted when a task's status changes.
class TaskStateChangedEvent {
  final String taskId;
  final TaskStatus oldStatus;
  final TaskStatus newStatus;
  final DateTime timestamp;

  TaskStateChangedEvent({
    required this.taskId,
    required this.oldStatus,
    required this.newStatus,
  }) : timestamp = DateTime.now();
}
