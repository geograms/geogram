/*
 * TaskMonitorService — central registry for background tasks.
 *
 * Mirrors parent geogram's lib/services/task_monitor_service.dart so a
 * shared package can be extracted later. Pure Dart, no Flutter deps.
 *
 * The motivating problem: the previous geogram implementation had
 * threads/loops spawning ad-hoc, with no way to know what was running,
 * how much CPU it consumed, what order it started in, or how to pause
 * non-critical work on a constrained device. This service is the single
 * choke point for *every* background task: register on start, report
 * each execution, optionally pause/resume. UI and debug API read from
 * the same registry.
 */

import 'dart:async';

import '../models/monitored_task.dart';
import 'event_bus.dart';

/// Singleton registry. Access via `TaskMonitorService()` or
/// `TaskMonitorService.instance` — both return the same instance.
class TaskMonitorService {
  TaskMonitorService._();
  static final TaskMonitorService instance = TaskMonitorService._();
  factory TaskMonitorService() => instance;

  final Map<String, MonitoredTask> _tasks = {};

  final StreamController<TaskStateChangedEvent> _stateChanges =
      StreamController<TaskStateChangedEvent>.broadcast();

  /// Stream of task status transitions. UI components (debug page,
  /// status bar) subscribe to this for live updates.
  Stream<TaskStateChangedEvent> get stateChanges => _stateChanges.stream;

  // ── Register / unregister ──────────────────────────────────────────

  void register(MonitoredTask task) {
    _tasks[task.id] = task;
  }

  void unregister(String id) {
    _tasks.remove(id);
  }

  // ── Lifecycle reporting (call around each execution) ───────────────

  void reportStart(String id) {
    final task = _tasks[id];
    if (task == null) return;
    final old = task.status;
    task.status = TaskStatus.running;
    task.lastRunAt = DateTime.now();
    task.runCount++;
    _emit(id, old, TaskStatus.running);
  }

  void reportSuccess(String id) {
    final task = _tasks[id];
    if (task == null) return;
    final old = task.status;
    task.successCount++;
    if (task.lastRunAt != null) {
      task.lastDuration = DateTime.now().difference(task.lastRunAt!);
      task.totalCpuMs += task.lastDuration!.inMilliseconds;
    }
    task.lastError = null;
    task.status = TaskStatus.idle;
    _emit(id, old, TaskStatus.idle);
  }

  void reportFailure(String id, Object error) {
    final task = _tasks[id];
    if (task == null) return;
    final old = task.status;
    task.failCount++;
    if (task.lastRunAt != null) {
      task.lastDuration = DateTime.now().difference(task.lastRunAt!);
    }
    task.lastError = error.toString();
    task.status = TaskStatus.error;
    _emit(id, old, TaskStatus.error);
    EventBus().fire(ErrorEvent(
      source: 'TaskMonitor:$id',
      message: error.toString(),
      error: error,
    ));
  }

  // ── Queries ────────────────────────────────────────────────────────

  List<MonitoredTask> get tasks => List.unmodifiable(_tasks.values);

  MonitoredTask? getTask(String id) => _tasks[id];

  Map<String, List<MonitoredTask>> get tasksByService {
    final map = <String, List<MonitoredTask>>{};
    for (final t in _tasks.values) {
      (map[t.serviceName] ??= []).add(t);
    }
    return map;
  }

  Map<TaskPriority, List<MonitoredTask>> get tasksByPriority {
    final map = <TaskPriority, List<MonitoredTask>>{};
    for (final t in _tasks.values) {
      (map[t.priority] ??= []).add(t);
    }
    return map;
  }

  // ── Pause / resume ─────────────────────────────────────────────────

  /// Pause a non-critical task. Returns false for critical tasks or
  /// unknown ids. Note: pausing only flips the status flag — owners
  /// must check `task.status == TaskStatus.paused` before doing work.
  bool pause(String id) {
    final task = _tasks[id];
    if (task == null) return false;
    if (task.priority == TaskPriority.critical) return false;
    final old = task.status;
    task.status = TaskStatus.paused;
    _emit(id, old, TaskStatus.paused);
    return true;
  }

  bool resume(String id) {
    final task = _tasks[id];
    if (task == null) return false;
    if (task.status != TaskStatus.paused) return false;
    final old = task.status;
    task.status = TaskStatus.idle;
    _emit(id, old, TaskStatus.idle);
    return true;
  }

  /// Pause every non-critical task that isn't already paused. Returns
  /// the number of tasks affected. Used when the device reports memory
  /// or thermal pressure.
  int pauseAllNonCritical() {
    var count = 0;
    for (final t in _tasks.values) {
      if (t.priority != TaskPriority.critical &&
          t.status != TaskStatus.paused) {
        final old = t.status;
        t.status = TaskStatus.paused;
        _emit(t.id, old, TaskStatus.paused);
        count++;
      }
    }
    return count;
  }

  int resumeAll() {
    var count = 0;
    for (final t in _tasks.values) {
      if (t.status == TaskStatus.paused) {
        final old = t.status;
        t.status = TaskStatus.idle;
        _emit(t.id, old, TaskStatus.idle);
        count++;
      }
    }
    return count;
  }

  // ── Summary (debug API) ────────────────────────────────────────────

  Map<String, dynamic> toJson() {
    final list = _tasks.values.map((t) => t.toJson()).toList();
    return {
      'success': true,
      'total': list.length,
      'running': _tasks.values
          .where((t) => t.status == TaskStatus.running)
          .length,
      'idle': _tasks.values.where((t) => t.status == TaskStatus.idle).length,
      'paused': _tasks.values
          .where((t) => t.status == TaskStatus.paused)
          .length,
      'error': _tasks.values.where((t) => t.status == TaskStatus.error).length,
      'tasks': list,
    };
  }

  // ── Internal ───────────────────────────────────────────────────────

  void _emit(String id, TaskStatus oldStatus, TaskStatus newStatus) {
    if (oldStatus == newStatus) return;
    _stateChanges.add(TaskStateChangedEvent(
      taskId: id,
      oldStatus: oldStatus,
      newStatus: newStatus,
    ));
  }
}

// ── Template process method ─────────────────────────────────────────
//
// Wrap any one-shot startup step in this helper so it auto-registers
// with the task monitor and reports start/success/failure. This is the
// pattern from parent geogram's main.dart `_initService`. Wapps and
// startup code should NOT roll their own try/catch around init steps —
// always go through here so the monitor sees them.
//
// [bootStart] tags the resulting MonitoredTask with how it participates
// in the boot phase. The default is [BootStart.parallel] — pass
// [BootStart.sequential] for heavy work that must not compete with
// other boot tasks. The actual scheduling of sequential vs parallel
// tasks is done by [BootOrchestrator]; runMonitoredStartup itself
// always runs immediately when called.

Future<void> runMonitoredStartup(
  String id,
  String name,
  Future<void> Function() init, {
  TaskPriority priority = TaskPriority.normal,
  String description = '',
  BootStart bootStart = BootStart.parallel,
}) async {
  final monitor = TaskMonitorService.instance;
  final taskId = 'startup.$id';
  final task = MonitoredTask(
    id: taskId,
    name: name,
    description: description.isEmpty ? name : description,
    serviceName: 'startup',
    priority: priority,
    type: TaskType.oneshot,
    bootStart: bootStart,
  );
  monitor.register(task);
  monitor.reportStart(taskId);
  final stopwatch = Stopwatch()..start();
  try {
    await init();
    stopwatch.stop();
    task.initWallMs = stopwatch.elapsedMilliseconds;
    task.initCpuMs = stopwatch.elapsedMilliseconds;
    monitor.reportSuccess(taskId);
  } catch (e) {
    stopwatch.stop();
    monitor.reportFailure(taskId, e);
    rethrow;
  }
}

// ── BootOrchestrator ────────────────────────────────────────────────
//
// Two-phase boot sequencer. Code that needs to run during geogram
// startup should call [BootOrchestrator.instance.register] *before*
// `runApp`, then `main()` calls [runAll] exactly once. Sequential
// tasks run first, alone, in registration order. Parallel tasks run
// after, all at once.
//
// Each task is run through [runMonitoredStartup], so they end up in
// the task monitor with the right `bootStart` attribute and the boot
// time recorded as `initWallMs`. Failures from sequential tasks rethrow
// — a heavy boot task that fails halts the boot sequence so the user
// sees a clear error instead of partial state. Failures from parallel
// tasks are isolated (the rest still run) but still visible in the
// monitor.

class _BootEntry {
  final String id;
  final String name;
  final Future<void> Function() init;
  final BootStart mode;
  final TaskPriority priority;
  final String description;
  _BootEntry(this.id, this.name, this.init, this.mode, this.priority,
      this.description);
}

class BootOrchestrator {
  BootOrchestrator._();
  static final BootOrchestrator instance = BootOrchestrator._();

  final List<_BootEntry> _pending = [];

  /// Register a task to run during the geogram boot phase. Must be
  /// called before [runAll]. Order matters for [BootStart.sequential]
  /// — tasks run in registration order, so register the most critical
  /// dependency first.
  void register({
    required String id,
    required String name,
    required Future<void> Function() init,
    BootStart mode = BootStart.parallel,
    TaskPriority priority = TaskPriority.normal,
    String description = '',
  }) {
    _pending.add(_BootEntry(id, name, init, mode, priority, description));
  }

  /// Run every registered boot task. Sequentials first, in order, one
  /// at a time. Then all parallels concurrently. Idempotent — calling
  /// twice is a no-op the second time because the pending list is
  /// drained.
  Future<void> runAll() async {
    if (_pending.isEmpty) return;
    final entries = List<_BootEntry>.from(_pending);
    _pending.clear();

    final sequential =
        entries.where((e) => e.mode == BootStart.sequential).toList();
    final parallel =
        entries.where((e) => e.mode == BootStart.parallel).toList();

    // Sequentials run alone, in order. A failure halts the sequence so
    // dependent boot tasks don't run with a broken precondition.
    for (final entry in sequential) {
      await _runOne(entry);
    }

    // Parallels run concurrently. Each is independent — one failing
    // does not abort the others.
    if (parallel.isNotEmpty) {
      await Future.wait(parallel.map(_runOneSafe));
    }
  }

  Future<void> _runOne(_BootEntry e) {
    return runMonitoredStartup(
      e.id, e.name, e.init,
      priority: e.priority,
      description: e.description,
      bootStart: e.mode,
    );
  }

  Future<void> _runOneSafe(_BootEntry e) async {
    try {
      await _runOne(e);
    } catch (_) {
      // Swallowed — runMonitoredStartup already reported the failure
      // to TaskMonitorService and EventBus. Other parallel tasks must
      // still run.
    }
  }

  /// Number of tasks still waiting to be run. Test/debug helper.
  int get pendingCount => _pending.length;
}
