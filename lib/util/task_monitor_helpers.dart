/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import '../models/monitored_task.dart';
import '../services/task_monitor_service.dart';

/// Drop-in replacement for [Timer.periodic] with task monitoring.
///
/// Auto-registers with [TaskMonitorService], reports start/success/fail
/// for each tick, and skips execution when the task is paused.
///
/// ```dart
/// _timer = MonitoredPeriodicTimer(
///   id: 'my_service.cleanup',
///   name: 'Cleanup',
///   description: 'Removes stale entries every 30s',
///   serviceName: 'MyService',
///   interval: Duration(seconds: 30),
///   priority: TaskPriority.low,
///   callback: (_) => _doCleanup(),
/// );
/// ```
class MonitoredPeriodicTimer {
  final String id;
  final Duration interval;
  final void Function(Timer timer) callback;
  Timer? _timer;

  MonitoredPeriodicTimer({
    required this.id,
    required String name,
    required String description,
    required String serviceName,
    required this.interval,
    required this.callback,
    TaskPriority priority = TaskPriority.normal,
  }) {
    final monitor = TaskMonitorService();
    monitor.register(MonitoredTask(
      id: id,
      name: name,
      description: description,
      serviceName: serviceName,
      priority: priority,
      type: TaskType.periodic,
      interval: interval,
    ));
    _timer = Timer.periodic(interval, _tick);
  }

  void _tick(Timer timer) {
    final monitor = TaskMonitorService();
    final task = monitor.getTask(id);
    if (task?.status == TaskStatus.paused) return;
    monitor.reportStart(id);
    try {
      callback(timer);
      monitor.reportSuccess(id);
    } catch (e) {
      monitor.reportFailure(id, e);
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    TaskMonitorService().unregister(id);
  }

  bool get isActive => _timer?.isActive ?? false;
}

/// Drop-in replacement for [Timer.periodic] with async callbacks.
///
/// Like [MonitoredPeriodicTimer] but awaits the callback and prevents
/// overlapping executions (skips tick if previous is still running).
///
/// ```dart
/// _timer = MonitoredAsyncPeriodicTimer(
///   id: 'dm_queue.process',
///   name: 'DM Queue Processor',
///   description: 'Delivers queued direct messages',
///   serviceName: 'DMQueueService',
///   interval: Duration(seconds: 10),
///   priority: TaskPriority.normal,
///   callback: (_) async => await processQueue(),
/// );
/// ```
class MonitoredAsyncPeriodicTimer {
  final String id;
  final Duration interval;
  final Future<void> Function(Timer timer) callback;
  Timer? _timer;
  bool _executing = false;

  MonitoredAsyncPeriodicTimer({
    required this.id,
    required String name,
    required String description,
    required String serviceName,
    required this.interval,
    required this.callback,
    TaskPriority priority = TaskPriority.normal,
  }) {
    final monitor = TaskMonitorService();
    monitor.register(MonitoredTask(
      id: id,
      name: name,
      description: description,
      serviceName: serviceName,
      priority: priority,
      type: TaskType.periodic,
      interval: interval,
    ));
    _timer = Timer.periodic(interval, _tick);
  }

  void _tick(Timer timer) {
    final monitor = TaskMonitorService();
    final task = monitor.getTask(id);
    if (task?.status == TaskStatus.paused) return;
    if (_executing) return; // overlap guard
    _executing = true;
    monitor.reportStart(id);
    callback(timer).then((_) {
      monitor.reportSuccess(id);
    }).catchError((e) {
      monitor.reportFailure(id, e);
    }).whenComplete(() {
      _executing = false;
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    TaskMonitorService().unregister(id);
  }

  bool get isActive => _timer?.isActive ?? false;
}

/// Handle for isolate / FFI tasks that can't share memory.
///
/// Register once, then call [markRunning], [markIdle], [markError]
/// from the main isolate when you get status updates.
///
/// ```dart
/// final handle = MonitoredIsolateHandle(
///   id: 'aprs.is_client',
///   name: 'APRS-IS Connection',
///   description: 'Maintains TCP connection to APRS-IS network',
///   serviceName: 'AprsService',
///   priority: TaskPriority.normal,
/// );
/// handle.markRunning();
/// ```
class MonitoredIsolateHandle {
  final String id;

  MonitoredIsolateHandle({
    required this.id,
    required String name,
    required String description,
    required String serviceName,
    TaskPriority priority = TaskPriority.normal,
  }) {
    TaskMonitorService().register(MonitoredTask(
      id: id,
      name: name,
      description: description,
      serviceName: serviceName,
      priority: priority,
      type: TaskType.isolate,
    ));
  }

  void markRunning() => TaskMonitorService().reportStart(id);
  void markIdle() => TaskMonitorService().reportSuccess(id);
  void markError(dynamic error) => TaskMonitorService().reportFailure(id, error);

  void dispose() => TaskMonitorService().unregister(id);
}
