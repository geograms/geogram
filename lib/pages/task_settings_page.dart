/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/monitored_task.dart';
import '../services/i18n_service.dart';
import '../services/task_monitor_service.dart';

enum _ViewMode { service, priority, performance }

class TaskSettingsPage extends StatefulWidget {
  const TaskSettingsPage({super.key});

  @override
  State<TaskSettingsPage> createState() => _TaskSettingsPageState();
}

class _TaskSettingsPageState extends State<TaskSettingsPage> {
  final TaskMonitorService _monitor = TaskMonitorService();
  final I18nService _i18n = I18nService();
  StreamSubscription<TaskStateChangedEvent>? _sub;
  _ViewMode _viewMode = _ViewMode.performance;

  @override
  void initState() {
    super.initState();
    _sub = _monitor.stateChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tasks = _monitor.tasks;

    return Scaffold(
      appBar: AppBar(title: Text(_i18n.t('task_monitor'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSummaryCard(theme, tasks),
          const SizedBox(height: 16),
          _buildViewToggle(theme),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            _buildEmptyState(theme)
          else if (_viewMode == _ViewMode.performance)
            ..._buildPerformanceView(theme, tasks)
          else
            ..._buildGroupedList(theme, tasks),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Summary card
  // ------------------------------------------------------------------

  Widget _buildSummaryCard(ThemeData theme, List<MonitoredTask> tasks) {
    final running = tasks.where((t) => t.status == TaskStatus.running).length;
    final idle = tasks.where((t) => t.status == TaskStatus.idle).length;
    final paused = tasks.where((t) => t.status == TaskStatus.paused).length;
    final error = tasks.where((t) => t.status == TaskStatus.error).length;
    final hasPaused = paused > 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _i18n.t('task_registered_count', params: ['${tasks.length}']),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip(_i18n.t('task_status_running'), running, Colors.blue),
                _chip(_i18n.t('task_status_idle'), idle, Colors.green),
                _chip(_i18n.t('task_status_paused'), paused, Colors.orange),
                _chip(_i18n.t('task_status_error'), error, Colors.red),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: Icon(hasPaused ? Icons.play_arrow : Icons.pause),
                label: Text(
                  hasPaused
                      ? _i18n.t('task_resume_all')
                      : _i18n.t('task_pause_all'),
                ),
                onPressed: () {
                  setState(() {
                    if (hasPaused) {
                      _monitor.resumeAll();
                    } else {
                      _monitor.pauseAllNonCritical();
                    }
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, int count, Color color) {
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6, child: null),
      label: Text('$label: $count'),
      visualDensity: VisualDensity.compact,
    );
  }

  // ------------------------------------------------------------------
  // View toggle (3-way)
  // ------------------------------------------------------------------

  Widget _buildViewToggle(ThemeData theme) {
    return SegmentedButton<_ViewMode>(
      segments: [
        const ButtonSegment(
          value: _ViewMode.performance,
          label: Text('Performance'),
        ),
        ButtonSegment(
          value: _ViewMode.service,
          label: Text(_i18n.t('task_group_by_service')),
        ),
        ButtonSegment(
          value: _ViewMode.priority,
          label: Text(_i18n.t('task_group_by_priority')),
        ),
      ],
      selected: {_viewMode},
      onSelectionChanged: (v) => setState(() => _viewMode = v.first),
    );
  }

  // ------------------------------------------------------------------
  // Performance view
  // ------------------------------------------------------------------

  List<Widget> _buildPerformanceView(
    ThemeData theme,
    List<MonitoredTask> tasks,
  ) {
    final rssMB = (ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1);
    final maxRssMB = (ProcessInfo.maxRss / 1024 / 1024).toStringAsFixed(1);

    final startupTasks =
        tasks.where((t) => t.id.startsWith('startup.')).toList()
          ..sort((a, b) => b.initCpuMs.compareTo(a.initCpuMs));

    final runtimeTasks = _monitor.performanceRuntimeTasks.toList()
      ..sort((a, b) => b.totalCpuMs.compareTo(a.totalCpuMs));

    final pausableRuntimeTasks = runtimeTasks
        .where(_monitor.canTogglePerformanceTask)
        .toList();
    final pausedRuntimeTaskCount = pausableRuntimeTasks
        .where((t) => t.status == TaskStatus.paused)
        .length;
    final hasPausedRuntimeTasks = pausedRuntimeTaskCount > 0;
    final hasRunningRuntimeTasks = pausableRuntimeTasks.any(
      (t) => t.status != TaskStatus.paused,
    );

    return [
      // Memory summary
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.memory, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('RSS: $rssMB MB', style: theme.textTheme.titleSmall),
                  Text('Peak: $maxRssMB MB', style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),

      // Continuous section — ongoing periodic tasks (shown first)
      if (runtimeTasks.isNotEmpty) ...[
        _sectionHeader(theme, 'CONTINUOUS (runtime tasks)'),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Cumulative CPU from background tasks while the app is open. '
            'Periodic tasks can be paused here without affecting startup stats.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        if (pausableRuntimeTasks.isNotEmpty) ...[
          _buildRuntimeControlsCard(
            theme,
            runtimeTaskCount: pausableRuntimeTasks.length,
            pausedTaskCount: pausedRuntimeTaskCount,
            canPause: hasRunningRuntimeTasks,
            canResume: hasPausedRuntimeTasks,
          ),
          const SizedBox(height: 8),
        ],
        ..._buildRuntimeRows(theme, runtimeTasks),
        const SizedBox(height: 16),
      ],

      // Startup section — one-time init costs
      if (startupTasks.isNotEmpty) ...[
        _sectionHeader(theme, 'STARTUP (one-time init)'),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'CPU time consumed during app launch. Each service ran once and is now idle.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        ..._buildStartupRows(theme, startupTasks),
        _buildStartupTotal(theme, startupTasks),
      ],

      if (startupTasks.isEmpty && runtimeTasks.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              'No profiling data yet. Restart the app to collect startup timings.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildStartupRows(ThemeData theme, List<MonitoredTask> tasks) {
    return tasks.map((t) {
      final rssMB = t.rssDeltaBytes / 1024 / 1024;
      final rssStr = '${rssMB >= 0 ? "+" : ""}${rssMB.toStringAsFixed(1)}';
      final cpuPct = tasks.first.initCpuMs > 0
          ? (t.initCpuMs / tasks.first.initCpuMs).clamp(0.0, 1.0)
          : 0.0;

      return ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: SizedBox(
          width: 60,
          child: Text(
            '${t.initCpuMs}ms',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: t == tasks.first ? FontWeight.bold : null,
              color: t.initCpuMs > 100 ? Colors.red : null,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(t.name, style: theme.textTheme.bodySmall),
            ),
            SizedBox(
              width: 60,
              child: Text(
                '${t.initWallMs}ms',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            SizedBox(
              width: 60,
              child: Text(
                '${rssStr}MB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: rssMB > 5 ? Colors.orange : theme.colorScheme.outline,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        subtitle: LinearProgressIndicator(
          value: cpuPct,
          minHeight: 3,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(
            t.initCpuMs > 100 ? Colors.red : theme.colorScheme.primary,
          ),
        ),
      );
    }).toList();
  }

  Widget _buildStartupTotal(ThemeData theme, List<MonitoredTask> tasks) {
    final totalCpu = tasks.fold<int>(0, (s, t) => s + t.initCpuMs);
    final totalWall = tasks.fold<int>(0, (s, t) => s + t.initWallMs);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            'Total: ${totalCpu}ms cpu, ${totalWall}ms wall',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRuntimeRows(ThemeData theme, List<MonitoredTask> tasks) {
    return tasks.map((t) {
      final avgMs = t.runCount > 0 ? t.totalCpuMs ~/ t.runCount : 0;
      final canToggle = _monitor.canTogglePerformanceTask(t);
      final intervalLabel = t.interval != null
          ? ' · every ${_formatDuration(t.interval!)}'
          : '';

      return ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: SizedBox(
          width: 60,
          child: Text(
            _formatMs(t.totalCpuMs),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              color: t.totalCpuMs > 5000 ? Colors.red : null,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(t.name, style: theme.textTheme.bodySmall)),
            const SizedBox(width: 8),
            _statusDot(t.status),
          ],
        ),
        subtitle: Text(
          '${t.runCount} runs, avg ${avgMs}ms$intervalLabel',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        trailing: canToggle
            ? IconButton(
                tooltip: t.status == TaskStatus.paused
                    ? 'Resume periodic task'
                    : 'Pause periodic task',
                icon: Icon(
                  t.status == TaskStatus.paused
                      ? Icons.play_arrow
                      : Icons.pause,
                ),
                onPressed: () => _toggleRuntimeTask(t),
              )
            : null,
      );
    }).toList();
  }

  Widget _buildRuntimeControlsCard(
    ThemeData theme, {
    required int runtimeTaskCount,
    required int pausedTaskCount,
    required bool canPause,
    required bool canResume,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$runtimeTaskCount periodic tasks can be paused from this view.',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              pausedTaskCount == 0
                  ? 'Startup and isolate tasks stay read-only so the controls reflect real CPU relief.'
                  : '$pausedTaskCount periodic tasks are currently paused.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: canPause ? _pauseShownRuntimeTasks : null,
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text('Pause shown periodic tasks'),
                ),
                OutlinedButton.icon(
                  onPressed: canResume ? _resumeShownRuntimeTasks : null,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Resume shown periodic tasks'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Empty state
  // ------------------------------------------------------------------

  Widget _buildEmptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.task_alt,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              _i18n.t('task_no_tasks'),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _i18n.t('task_no_tasks_hint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Grouped list (service / priority views)
  // ------------------------------------------------------------------

  List<Widget> _buildGroupedList(ThemeData theme, List<MonitoredTask> tasks) {
    if (_viewMode == _ViewMode.service) {
      final groups = _monitor.tasksByService;
      final keys = groups.keys.toList()..sort();
      return [
        for (final key in keys) ...[
          _sectionHeader(theme, key),
          for (final task in groups[key]!) _buildTaskTile(theme, task),
        ],
      ];
    } else {
      final groups = _monitor.tasksByPriority;
      final order = [
        TaskPriority.critical,
        TaskPriority.normal,
        TaskPriority.low,
      ];
      return [
        for (final p in order)
          if (groups.containsKey(p)) ...[
            _sectionHeader(theme, p.name.toUpperCase()),
            for (final task in groups[p]!) _buildTaskTile(theme, task),
          ],
      ];
    }
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4, left: 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Individual task tile
  // ------------------------------------------------------------------

  Widget _buildTaskTile(ThemeData theme, MonitoredTask task) {
    final ago = task.lastRunAt != null
        ? _formatAgo(DateTime.now().difference(task.lastRunAt!))
        : _i18n.t('task_last_run_never');
    final dur = task.lastDuration != null
        ? _formatDuration(task.lastDuration!)
        : '-';
    final subtitle = _i18n.t(
      'task_last_run',
      params: [ago, dur, '${task.runCount}'],
    );

    return ExpansionTile(
      leading: _statusDot(task.status),
      title: Text(task.name),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _priorityBadge(theme, task.priority),
          if (task.interval != null) ...[
            const SizedBox(width: 6),
            Text(
              _formatDuration(task.interval!),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.description, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(
                _i18n.t(
                  'task_success_fail',
                  params: ['${task.successCount}', '${task.failCount}'],
                ),
                style: theme.textTheme.bodySmall,
              ),
              if (task.lastError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _i18n.t('task_error_label', params: [task.lastError!]),
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(_i18n.t('task_paused_switch')),
                  const Spacer(),
                  Switch(
                    value: task.status == TaskStatus.paused,
                    onChanged: task.priority == TaskPriority.critical
                        ? null
                        : (paused) {
                            setState(() {
                              if (paused) {
                                _monitor.pause(task.id);
                              } else {
                                _monitor.resume(task.id);
                              }
                            });
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  Widget _statusDot(TaskStatus status) {
    final color = switch (status) {
      TaskStatus.idle => Colors.green,
      TaskStatus.running => Colors.blue,
      TaskStatus.paused => Colors.orange,
      TaskStatus.error => Colors.red,
    };
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  void _toggleRuntimeTask(MonitoredTask task) {
    final paused = task.status == TaskStatus.paused;
    final ok = paused ? _monitor.resume(task.id) : _monitor.pause(task.id);
    if (!ok) return;
    setState(() {});
    _showRuntimeTaskSnackBar(
      paused ? 'Resumed ${task.name}' : 'Paused ${task.name}',
    );
  }

  void _pauseShownRuntimeTasks() {
    final pausedCount = _monitor.pausePerformanceTasks();
    setState(() {});
    _showRuntimeTaskSnackBar(
      pausedCount == 0
          ? 'No periodic runtime tasks could be paused.'
          : 'Paused $pausedCount periodic runtime tasks.',
    );
  }

  void _resumeShownRuntimeTasks() {
    final resumedCount = _monitor.resumePerformanceTasks();
    setState(() {});
    _showRuntimeTaskSnackBar(
      resumedCount == 0
          ? 'No periodic runtime tasks were paused.'
          : 'Resumed $resumedCount periodic runtime tasks.',
    );
  }

  void _showRuntimeTaskSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Widget _priorityBadge(ThemeData theme, TaskPriority priority) {
    final (label, color) = switch (priority) {
      TaskPriority.critical => (_i18n.t('task_priority_critical'), Colors.red),
      TaskPriority.normal => (_i18n.t('task_priority_normal'), Colors.grey),
      TaskPriority.low => (_i18n.t('task_priority_low'), Colors.blueGrey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: color.withValues(alpha: 0.2),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  String _formatAgo(Duration d) {
    if (d.inDays > 0) return _i18n.t('task_ago_days', params: ['${d.inDays}']);
    if (d.inHours > 0) {
      return _i18n.t('task_ago_hours', params: ['${d.inHours}']);
    }
    if (d.inMinutes > 0) {
      return _i18n.t('task_ago_minutes', params: ['${d.inMinutes}']);
    }
    return _i18n.t('task_ago_seconds', params: ['${d.inSeconds}']);
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) {
      return '${d.inSeconds}.${(d.inMilliseconds % 1000) ~/ 100}s';
    }
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  String _formatMs(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${ms ~/ 60000}m${(ms % 60000) ~/ 1000}s';
  }
}
