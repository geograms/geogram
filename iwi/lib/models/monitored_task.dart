/*
 * MonitoredTask — value object for tasks tracked by [TaskMonitorService].
 *
 * Mirrors parent geogram's lib/models/monitored_task.dart so a shared
 * package can be extracted later. Pure Dart, no Flutter deps.
 */

/// Priority level for monitored tasks. Critical tasks cannot be paused.
enum TaskPriority {
  critical,
  normal,
  low,
}

/// Execution pattern of a monitored task.
enum TaskType {
  /// Runs on a periodic timer.
  periodic,

  /// Runs in a separate isolate.
  isolate,

  /// Runs once and reports completion.
  oneshot,
}

/// Runtime status of a monitored task.
enum TaskStatus {
  idle,
  running,
  paused,
  error,
}

/// How a task participates in the geogram boot phase. Used by the
/// [BootOrchestrator] to schedule heavy startup work without competing
/// with everything else for CPU and memory at the same time.
enum BootStart {
  /// Not a boot task — runs ad-hoc later, on demand.
  none,

  /// Runs concurrently with every other parallel boot task. Default
  /// for ordinary lightweight initialisation. Use this unless the task
  /// is heavy enough that running it alongside other work would spike
  /// memory or CPU.
  parallel,

  /// Runs alone, in registration order, before any parallel boot
  /// tasks. Use for heavy initialisation (P2P bootstrap, mirror sync,
  /// large database open, hardware probes) that must not compete with
  /// other boot work on memory-constrained devices.
  sequential,
}

/// A background task registered with [TaskMonitorService]. Lifecycle:
///
///   1. Owner constructs and calls `register(task)`.
///   2. Around each execution, owner calls `reportStart(id)`, then
///      either `reportSuccess(id)` or `reportFailure(id, err)`.
///   3. UI / debug tools observe via `tasks` and `stateChanges`.
///   4. Owner calls `unregister(id)` before disposing.
class MonitoredTask {
  /// Compound identifier — convention is `serviceName.taskName`.
  final String id;

  /// Human-readable name.
  final String name;

  /// Mutable description (progress text etc.).
  String description;

  /// Owning service name. Used by [TaskMonitorService.tasksByService].
  final String serviceName;

  final TaskPriority priority;
  final TaskType type;

  /// How this task participates in the geogram boot phase. Default
  /// [BootStart.none] — only the [BootOrchestrator] / runMonitoredStartup
  /// path sets this to anything else.
  final BootStart bootStart;

  /// Repeat interval — null for [TaskType.oneshot] / [TaskType.isolate].
  final Duration? interval;

  // ── Runtime state (mutable) ──────────────────────────────────────

  TaskStatus status;
  DateTime? lastRunAt;
  Duration? lastDuration;
  int runCount;
  int successCount;
  int failCount;
  String? lastError;
  final DateTime registeredAt;

  // ── CPU profiling (mutable) ──────────────────────────────────────

  /// Cumulative wall-clock time across all runs (ms).
  int totalCpuMs;

  /// One-shot init wall-clock time (ms). Set for [TaskType.oneshot].
  int initCpuMs;
  int initWallMs;

  /// RSS change during init (bytes, can be negative). Reserved for the
  /// future native-side memory probe; default 0.
  int rssDeltaBytes;

  MonitoredTask({
    required this.id,
    required this.name,
    required this.description,
    required this.serviceName,
    required this.priority,
    required this.type,
    this.bootStart = BootStart.none,
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
        'bootStart': bootStart.name,
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

/// Emitted by [TaskMonitorService] whenever a task transitions status.
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
