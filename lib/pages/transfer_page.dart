import 'dart:async';

import 'package:flutter/material.dart';

import '../transfer/models/transfer_metrics.dart';
import '../transfer/models/transfer_models.dart';
import '../transfer/services/transfer_metrics_service.dart';
import '../transfer/services/transfer_service.dart';
import '../util/event_bus.dart';
import '../widgets/transfer/transfer_activity_chart.dart';
import '../widgets/transfer/transfer_list_item.dart';
import '../widgets/transfer/transfer_metrics_card.dart';

/// Main Transfer Center page
///
/// Features:
/// - Tab-based view: Active | Queued | Completed | Failed | Stats
/// - Real-time progress updates
/// - Swipe actions (pause, cancel, retry)
/// - Settings access
/// - Metrics summary card
class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TransferService _service = TransferService();
  final TransferMetricsService _metricsService = TransferMetricsService();
  final EventBus _eventBus = EventBus();

  TransferMetrics _metrics = const TransferMetrics();
  List<Transfer> _activeTransfers = [];
  List<Transfer> _queuedTransfers = [];
  List<Transfer> _completedTransfers = [];
  List<Transfer> _failedTransfers = [];
  List<TransferHistoryPoint> _historyPoints = [];

  bool _isLoading = true;
  String? _error;

  StreamSubscription? _metricsSubscription;
  EventSubscription<TransferProgressEvent>? _progressSubscription;
  EventSubscription<TransferCompletedEvent>? _completedSubscription;
  EventSubscription<TransferFailedEvent>? _failedSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _initService();
  }

  Future<void> _initService() async {
    try {
      if (!_service.isInitialized) {
        await _service.initialize();
      }
      await _metricsService.initialize();

      // Subscribe to updates
      _metricsSubscription = _service.metricsStream.listen((metrics) {
        if (mounted) {
          setState(() => _metrics = metrics);
        }
      });

      _progressSubscription = _eventBus.on<TransferProgressEvent>((event) {
        _refreshData();
      });

      _completedSubscription = _eventBus.on<TransferCompletedEvent>((event) {
        _refreshData();
      });

      _failedSubscription = _eventBus.on<TransferFailedEvent>((event) {
        _refreshData();
      });

      await _refreshData();

      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _refreshData() async {
    try {
      final metrics = _service.getMetrics();
      final active = _service.getActiveTransfers();
      final queued = _service.getQueuedTransfers();
      final completed = _service.getCompletedTransfers();
      final failed = _service.getFailedTransfers();
      final history = _metricsService.getHistory(
        period: const Duration(days: 1),
        resolution: const Duration(hours: 1),
      );

      if (mounted) {
        setState(() {
          _metrics = metrics;
          _activeTransfers = active;
          _queuedTransfers = queued;
          _completedTransfers = completed;
          _failedTransfers = failed;
          _historyPoints = history;
        });
      }
    } catch (e) {
      // Silently fail refresh
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _metricsSubscription?.cancel();
    _progressSubscription?.cancel();
    _completedSubscription?.cancel();
    _failedSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transfers')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transfers')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('Error initializing transfers',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, style: theme.textTheme.bodySmall),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _error = null;
                  });
                  _initService();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer Center'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettings,
            tooltip: 'Settings',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshData,
            tooltip: 'Refresh',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            _buildTab(
                'Active', _activeTransfers.length, Icons.sync, Colors.blue),
            _buildTab('Queued', _queuedTransfers.length, Icons.queue,
                Colors.orange),
            _buildTab('Completed', _completedTransfers.length,
                Icons.check_circle, Colors.green),
            _buildTab(
                'Failed', _failedTransfers.length, Icons.error, Colors.red),
            const Tab(icon: Icon(Icons.analytics), text: 'Stats'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildActiveTab(),
          _buildQueuedTab(),
          _buildCompletedTab(),
          _buildFailedTab(),
          _buildStatsTab(),
        ],
      ),
    );
  }

  Tab _buildTab(String label, int count, IconData icon, Color color) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 4),
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveTab() {
    if (_activeTransfers.isEmpty) {
      return _buildEmptyState(
        'No active transfers',
        'Transfers in progress will appear here',
        Icons.sync,
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount: _activeTransfers.length,
        itemBuilder: (context, index) {
          final transfer = _activeTransfers[index];
          return TransferListItem(
            transfer: transfer,
            onPause: transfer.canPause
                ? () => _service.pause(transfer.id)
                : null,
            onCancel: transfer.canCancel
                ? () => _confirmCancel(transfer)
                : null,
          );
        },
      ),
    );
  }

  Widget _buildQueuedTab() {
    if (_queuedTransfers.isEmpty) {
      return _buildEmptyState(
        'No queued transfers',
        'Pending transfers will appear here',
        Icons.queue,
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount: _queuedTransfers.length,
        itemBuilder: (context, index) {
          final transfer = _queuedTransfers[index];
          return TransferListItem(
            transfer: transfer,
            onResume: transfer.canResume
                ? () => _service.resume(transfer.id)
                : null,
            onCancel: transfer.canCancel
                ? () => _confirmCancel(transfer)
                : null,
          );
        },
      ),
    );
  }

  Widget _buildCompletedTab() {
    if (_completedTransfers.isEmpty) {
      return _buildEmptyState(
        'No completed transfers',
        'Successfully completed transfers will appear here',
        Icons.check_circle,
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount: _completedTransfers.length,
        itemBuilder: (context, index) {
          final transfer = _completedTransfers[index];
          return TransferListItem(transfer: transfer);
        },
      ),
    );
  }

  Widget _buildFailedTab() {
    if (_failedTransfers.isEmpty) {
      return _buildEmptyState(
        'No failed transfers',
        'Failed transfers will appear here',
        Icons.error_outline,
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: Column(
        children: [
          // Retry all button
          if (_failedTransfers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton.icon(
                onPressed: () async {
                  await _service.retryAll();
                  _refreshData();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry All'),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: _failedTransfers.length,
              itemBuilder: (context, index) {
                final transfer = _failedTransfers[index];
                return TransferListItem(
                  transfer: transfer,
                  onRetry: transfer.canRetry
                      ? () async {
                          await _service.retry(transfer.id);
                          _refreshData();
                        }
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsTab() {
    return RefreshIndicator(
      onRefresh: _refreshData,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 80),
        child: Column(
          children: [
            TransferMetricsCard(metrics: _metrics),
            TransferActivityChart(
              history: _historyPoints,
              periodStats: _metrics.today,
              onPeriodChanged: (period) {
                final history = _metricsService.getHistory(
                  period: period,
                  resolution: period.inDays <= 1
                      ? const Duration(hours: 1)
                      : const Duration(days: 1),
                );
                setState(() => _historyPoints = history);
              },
            ),
            TransportBreakdownChart(byTransport: _metrics.byTransport),
            _buildCallsignLeaderboard(),
          ],
        ),
      ),
    );
  }

  Widget _buildCallsignLeaderboard() {
    final theme = Theme.of(context);

    if (_metrics.topCallsigns.isEmpty) {
      return const SizedBox();
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Top Transfer Partners',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ..._metrics.topCallsigns.take(5).map((stats) => _buildCallsignRow(stats)),
          ],
        ),
      ),
    );
  }

  Widget _buildCallsignRow(CallsignStats stats) {
    final theme = Theme.of(context);
    final index = _metrics.topCallsigns.indexOf(stats) + 1;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: index <= 3
                  ? [Colors.amber, Colors.grey, Colors.brown][index - 1]
                      .withOpacity(0.2)
                  : theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$index',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            stats.callsign,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.upload, size: 12, color: Colors.green),
          Text(' ${stats.uploadCount}', style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          Icon(Icons.download, size: 12, color: Colors.blue),
          Text(' ${stats.downloadCount}', style: theme.textTheme.bodySmall),
          const Spacer(),
          Text(
            _formatBytes(stats.totalBytes),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String title, String subtitle, IconData icon) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SettingsSheet(
        settings: _service.settings,
        onSave: (settings) async {
          await _service.updateSettings(settings);
          _refreshData();
        },
      ),
    );
  }

  void _confirmCancel(Transfer transfer) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Transfer'),
        content: Text('Cancel transfer of "${transfer.filename}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _service.cancel(transfer.id);
              _refreshData();
            },
            child: const Text('Cancel Transfer'),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Settings bottom sheet
class _SettingsSheet extends StatefulWidget {
  final TransferSettings settings;
  final Future<void> Function(TransferSettings) onSave;

  const _SettingsSheet({
    required this.settings,
    required this.onSave,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late TransferSettings _settings;
  final _banController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _settings = widget.settings.copyWith();
  }

  @override
  void dispose() {
    _banController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.5,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('Settings', style: theme.textTheme.titleLarge),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    await widget.onSave(_settings);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
          const Divider(),
          // Content
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              children: [
                // Enabled toggle
                SwitchListTile(
                  title: const Text('Enable Transfers'),
                  subtitle: const Text('Process queued transfers automatically'),
                  value: _settings.enabled,
                  onChanged: (value) {
                    setState(() => _settings = _settings.copyWith(enabled: value));
                  },
                ),
                const Divider(),

                // Concurrent transfers
                ListTile(
                  title: const Text('Concurrent Transfers'),
                  subtitle: Slider(
                    value: _settings.maxConcurrentTransfers.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: '${_settings.maxConcurrentTransfers}',
                    onChanged: (value) {
                      setState(() => _settings = _settings.copyWith(
                            maxConcurrentTransfers: value.round(),
                          ));
                    },
                  ),
                  trailing: Text('${_settings.maxConcurrentTransfers}'),
                ),

                // Max retries
                ListTile(
                  title: const Text('Max Retries'),
                  subtitle: Slider(
                    value: _settings.maxRetries.toDouble(),
                    min: 1,
                    max: 20,
                    divisions: 19,
                    label: '${_settings.maxRetries}',
                    onChanged: (value) {
                      setState(() => _settings = _settings.copyWith(
                            maxRetries: value.round(),
                          ));
                    },
                  ),
                  trailing: Text('${_settings.maxRetries}'),
                ),

                const Divider(),

                // Ban list
                ListTile(
                  title: const Text('Banned Callsigns'),
                  subtitle: Text(
                    _settings.bannedCallsigns.isEmpty
                        ? 'No banned callsigns'
                        : '${_settings.bannedCallsigns.length} banned',
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: _settings.bannedCallsigns
                      .map((callsign) => Chip(
                            label: Text(callsign),
                            onDeleted: () {
                              setState(() {
                                final list =
                                    List<String>.from(_settings.bannedCallsigns);
                                list.remove(callsign);
                                _settings = _settings.copyWith(
                                  bannedCallsigns: list,
                                );
                              });
                            },
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _banController,
                        decoration: const InputDecoration(
                          labelText: 'Add callsign to ban',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        textCapitalization: TextCapitalization.characters,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: () {
                        final callsign = _banController.text.trim().toUpperCase();
                        if (callsign.isNotEmpty &&
                            !_settings.bannedCallsigns.contains(callsign)) {
                          setState(() {
                            final list =
                                List<String>.from(_settings.bannedCallsigns);
                            list.add(callsign);
                            _settings =
                                _settings.copyWith(bannedCallsigns: list);
                            _banController.clear();
                          });
                        }
                      },
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
