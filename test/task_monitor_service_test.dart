import 'package:flutter_test/flutter_test.dart';

import 'package:geogram/models/monitored_task.dart';
import 'package:geogram/services/task_monitor_service.dart';

void main() {
  final monitor = TaskMonitorService();

  void clearMonitor() {
    for (final task in monitor.tasks.toList()) {
      monitor.unregister(task.id);
    }
  }

  setUp(clearMonitor);
  tearDown(clearMonitor);

  test(
    'pausePerformanceTasks only pauses non-critical periodic runtime tasks',
    () {
      final periodicRuntime = MonitoredTask(
        id: 'dm_queue.process',
        name: 'DM Queue',
        description: 'Processes queued DMs',
        serviceName: 'DMQueueService',
        priority: TaskPriority.normal,
        type: TaskType.periodic,
        interval: const Duration(seconds: 10),
        totalCpuMs: 1200,
      );
      final alreadyPausedPeriodic = MonitoredTask(
        id: 'chat_queue.process',
        name: 'Chat Queue',
        description: 'Processes queued chat messages',
        serviceName: 'StationChatQueueService',
        priority: TaskPriority.low,
        type: TaskType.periodic,
        interval: const Duration(seconds: 10),
        status: TaskStatus.paused,
        totalCpuMs: 900,
      );
      final isolateRuntime = MonitoredTask(
        id: 'p2p_discovery.dht',
        name: 'P2P Discovery',
        description: 'Performs DHT discovery',
        serviceName: 'P2PService',
        priority: TaskPriority.normal,
        type: TaskType.isolate,
        totalCpuMs: 5000,
      );
      final criticalPeriodic = MonitoredTask(
        id: 'critical.timer',
        name: 'Critical Timer',
        description: 'Critical periodic task',
        serviceName: 'CriticalService',
        priority: TaskPriority.critical,
        type: TaskType.periodic,
        interval: const Duration(seconds: 5),
        totalCpuMs: 100,
      );
      final startupTask = MonitoredTask(
        id: 'startup.init',
        name: 'Startup Init',
        description: 'One-shot startup work',
        serviceName: 'StartupService',
        priority: TaskPriority.normal,
        type: TaskType.oneshot,
        initCpuMs: 150,
      );

      for (final task in [
        periodicRuntime,
        alreadyPausedPeriodic,
        isolateRuntime,
        criticalPeriodic,
        startupTask,
      ]) {
        monitor.register(task);
      }

      expect(
        monitor.performanceRuntimeTasks.map((task) => task.id),
        containsAll(<String>[
          'dm_queue.process',
          'chat_queue.process',
          'p2p_discovery.dht',
          'critical.timer',
        ]),
      );
      expect(
        monitor.performanceRuntimeTasks.map((task) => task.id),
        isNot(contains('startup.init')),
      );
      expect(monitor.canTogglePerformanceTask(periodicRuntime), isTrue);
      expect(monitor.canTogglePerformanceTask(alreadyPausedPeriodic), isTrue);
      expect(monitor.canTogglePerformanceTask(isolateRuntime), isFalse);
      expect(monitor.canTogglePerformanceTask(criticalPeriodic), isFalse);

      final pausedCount = monitor.pausePerformanceTasks();

      expect(pausedCount, 1);
      expect(periodicRuntime.status, TaskStatus.paused);
      expect(alreadyPausedPeriodic.status, TaskStatus.paused);
      expect(isolateRuntime.status, TaskStatus.idle);
      expect(criticalPeriodic.status, TaskStatus.idle);
    },
  );

  test('resumePerformanceTasks resumes only paused periodic runtime tasks', () {
    final pausedPeriodic = MonitoredTask(
      id: 'dm_queue.process',
      name: 'DM Queue',
      description: 'Processes queued DMs',
      serviceName: 'DMQueueService',
      priority: TaskPriority.normal,
      type: TaskType.periodic,
      interval: const Duration(seconds: 10),
      status: TaskStatus.paused,
      totalCpuMs: 1200,
    );
    final pausedIsolate = MonitoredTask(
      id: 'p2p_discovery.dht',
      name: 'P2P Discovery',
      description: 'Performs DHT discovery',
      serviceName: 'P2PService',
      priority: TaskPriority.normal,
      type: TaskType.isolate,
      status: TaskStatus.paused,
      totalCpuMs: 5000,
    );

    monitor.register(pausedPeriodic);
    monitor.register(pausedIsolate);

    final resumedCount = monitor.resumePerformanceTasks();

    expect(resumedCount, 1);
    expect(pausedPeriodic.status, TaskStatus.idle);
    expect(pausedIsolate.status, TaskStatus.paused);
  });
}
