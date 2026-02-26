/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/monitored_task.dart';
import '../services/task_monitor_service.dart';

class TaskSettingsPage extends StatefulWidget {
  const TaskSettingsPage({super.key});

  @override
  State<TaskSettingsPage> createState() => _TaskSettingsPageState();
}

class _TaskSettingsPageState extends State<TaskSettingsPage> {
  final TaskMonitorService _monitor = TaskMonitorService();
  StreamSubscription<TaskStateChangedEvent>? _sub;
  bool _groupByService = true; // false = group by priority

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
      appBar: AppBar(title: const Text('Background Tasks')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSummaryCard(theme, tasks),
          const SizedBox(height: 16),
          _buildGroupToggle(theme),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            _buildEmptyState(theme)
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
    final running =
        tasks.where((t) => t.status == TaskStatus.running).length;
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
              '${tasks.length} registered tasks',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip('Running', running, Colors.blue),
                _chip('Idle', idle, Colors.green),
                _chip('Paused', paused, Colors.orange),
                _chip('Error', error, Colors.red),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: Icon(hasPaused ? Icons.play_arrow : Icons.pause),
                label: Text(hasPaused ? 'Resume all' : 'Pause all non-critical'),
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
      avatar: CircleAvatar(
        backgroundColor: color,
        radius: 6,
        child: null,
      ),
      label: Text('$label: $count'),
      visualDensity: VisualDensity.compact,
    );
  }

  // ------------------------------------------------------------------
  // Group toggle
  // ------------------------------------------------------------------

  Widget _buildGroupToggle(ThemeData theme) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, label: Text('By Service')),
        ButtonSegment(value: false, label: Text('By Priority')),
      ],
      selected: {_groupByService},
      onSelectionChanged: (v) => setState(() => _groupByService = v.first),
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
            Icon(Icons.task_alt, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'No tasks registered yet',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Services will appear here as they adopt the task monitor.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Grouped list
  // ------------------------------------------------------------------

  List<Widget> _buildGroupedList(ThemeData theme, List<MonitoredTask> tasks) {
    if (_groupByService) {
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
      final order = [TaskPriority.critical, TaskPriority.normal, TaskPriority.low];
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
        : 'never';
    final dur = task.lastDuration != null
        ? _formatDuration(task.lastDuration!)
        : '-';
    final subtitle = 'Last run: $ago · $dur · ${task.runCount} runs';

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
                'Success: ${task.successCount} · Fail: ${task.failCount}',
                style: theme.textTheme.bodySmall,
              ),
              if (task.lastError != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Error: ${task.lastError}',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Paused'),
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

  Widget _priorityBadge(ThemeData theme, TaskPriority priority) {
    final (label, color) = switch (priority) {
      TaskPriority.critical => ('CRIT', Colors.red),
      TaskPriority.normal => ('NORM', Colors.grey),
      TaskPriority.low => ('LOW', Colors.blueGrey),
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
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    if (d.inMinutes > 0) return '${d.inMinutes}m ago';
    return '${d.inSeconds}s ago';
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) return '${d.inSeconds}.${(d.inMilliseconds % 1000) ~/ 100}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}
