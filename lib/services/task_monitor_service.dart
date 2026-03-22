/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import '../models/monitored_task.dart';
import 'log_service.dart';

/// Centralized registry for all background tasks.
///
/// Services register their tasks here so we have a single place to
/// inspect status, pause/resume non-critical work, and surface errors.
class TaskMonitorService {
  TaskMonitorService._();
  static final TaskMonitorService _instance = TaskMonitorService._();
  factory TaskMonitorService() => _instance;

  final Map<String, MonitoredTask> _tasks = {};

  final StreamController<TaskStateChangedEvent> _stateChanges =
      StreamController<TaskStateChangedEvent>.broadcast();

  /// Stream of task state changes for UI updates.
  Stream<TaskStateChangedEvent> get stateChanges => _stateChanges.stream;

  // ------------------------------------------------------------------
  // Register / unregister
  // ------------------------------------------------------------------

  void register(MonitoredTask task) {
    _tasks[task.id] = task;
    LogService().log('TaskMonitor: registered ${task.id}');
  }

  void unregister(String id) {
    _tasks.remove(id);
    LogService().log('TaskMonitor: unregistered $id');
  }

  // ------------------------------------------------------------------
  // Lifecycle reporting — services call these around each execution
  // ------------------------------------------------------------------

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

  void reportFailure(String id, dynamic error) {
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
  }

  // ------------------------------------------------------------------
  // Queries
  // ------------------------------------------------------------------

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

  // ------------------------------------------------------------------
  // Pause / resume
  // ------------------------------------------------------------------

  /// Pause a task. Refuses critical tasks (returns false).
  bool pause(String id) {
    final task = _tasks[id];
    if (task == null) return false;
    if (task.priority == TaskPriority.critical) return false;
    final old = task.status;
    task.status = TaskStatus.paused;
    _emit(id, old, TaskStatus.paused);
    LogService().log('TaskMonitor: paused $id');
    return true;
  }

  /// Resume a paused task.
  bool resume(String id) {
    final task = _tasks[id];
    if (task == null) return false;
    if (task.status != TaskStatus.paused) return false;
    final old = task.status;
    task.status = TaskStatus.idle;
    _emit(id, old, TaskStatus.idle);
    LogService().log('TaskMonitor: resumed $id');
    return true;
  }

  /// Pause all non-critical tasks at once.
  int pauseAllNonCritical() {
    int count = 0;
    for (final t in _tasks.values) {
      if (t.priority != TaskPriority.critical &&
          t.status != TaskStatus.paused) {
        final old = t.status;
        t.status = TaskStatus.paused;
        _emit(t.id, old, TaskStatus.paused);
        count++;
      }
    }
    if (count > 0) LogService().log('TaskMonitor: paused $count non-critical tasks');
    return count;
  }

  /// Resume all paused tasks.
  int resumeAll() {
    int count = 0;
    for (final t in _tasks.values) {
      if (t.status == TaskStatus.paused) {
        final old = t.status;
        t.status = TaskStatus.idle;
        _emit(t.id, old, TaskStatus.idle);
        count++;
      }
    }
    if (count > 0) LogService().log('TaskMonitor: resumed $count tasks');
    return count;
  }

  // ------------------------------------------------------------------
  // Summary (used by debug API)
  // ------------------------------------------------------------------

  Map<String, dynamic> toJson() {
    final list = _tasks.values.map((t) => t.toJson()).toList();
    return {
      'success': true,
      'total': list.length,
      'running': _tasks.values.where((t) => t.status == TaskStatus.running).length,
      'idle': _tasks.values.where((t) => t.status == TaskStatus.idle).length,
      'paused': _tasks.values.where((t) => t.status == TaskStatus.paused).length,
      'error': _tasks.values.where((t) => t.status == TaskStatus.error).length,
      'tasks': list,
    };
  }

  // ------------------------------------------------------------------
  // Internal
  // ------------------------------------------------------------------

  void _emit(String id, TaskStatus old, TaskStatus next) {
    if (old == next) return;
    _stateChanges.add(TaskStateChangedEvent(
      taskId: id,
      oldStatus: old,
      newStatus: next,
    ));
  }
}
