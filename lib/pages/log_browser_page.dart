/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../services/log_service.dart';
import '../services/crash_service.dart';
import '../services/i18n_service.dart';

/// Log browser page with performant line-based display
class LogBrowserPage extends StatefulWidget {
  const LogBrowserPage({super.key});

  @override
  State<LogBrowserPage> createState() => _LogBrowserPageState();
}

class _LogBrowserPageState extends State<LogBrowserPage> with SingleTickerProviderStateMixin {
  final LogService _logService = LogService();
  final CrashService _crashService = CrashService();
  final I18nService _i18n = I18nService();
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  final ScrollController _crashScrollController = ScrollController();

  late TabController _tabController;
  bool _isPaused = false;
  String _filterText = '';
  String? _crashLogs;
  Map<String, dynamic>? _heartbeat;
  bool _isLoadingLogFiles = true;

  // Performance: store log lines instead of full string
  List<String> _logLines = [];
  int _totalLogLines = 0;
  bool _logsTruncated = false;

  // Debounce timer for incoming log messages
  Timer? _updateTimer;
  final List<String> _pendingLines = [];

  // Track which crash cards have expanded stack traces (by index)
  final Set<int> _expandedCrashCards = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _logService.addListener(_onLogUpdate);
    _loadLogFiles();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _tabController.removeListener(_onTabChanged);
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _logService.removeListener(_onLogUpdate);
    _filterController.dispose();
    _logScrollController.dispose();
    _crashScrollController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;

    if (_tabController.index == 0) {
      _loadCrashLogs();
    } else if (_tabController.index == 1) {
      _reloadAndScrollToBottom();
    }
  }

  Future<void> _reloadAndScrollToBottom() async {
    await _loadLogFiles();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  void _onLogUpdate(String message) {
    if (_isPaused || !mounted || message.isEmpty) return;

    _pendingLines.add(message);

    // Debounce: flush pending lines every 300ms
    _updateTimer?.cancel();
    _updateTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _pendingLines.isEmpty) return;

      setState(() {
        _logLines.addAll(_pendingLines);
        _pendingLines.clear();
        // Cap at 1000 lines
        if (_logLines.length > 1000) {
          _logLines = _logLines.sublist(_logLines.length - 1000);
          _logsTruncated = true;
        }
        _totalLogLines = _logLines.length;
      });

      if (_tabController.index == 1) {
        _scrollToBottom();
      }
    });
  }

  Future<void> _loadLogFiles() async {
    // Show in-memory messages instantly (no I/O, no spinner)
    final inMemory = _logService.messages;
    if (inMemory.isNotEmpty) {
      setState(() {
        _logLines = List<String>.from(inMemory);
        _totalLogLines = inMemory.length;
        _logsTruncated = false;
        _isLoadingLogFiles = false;
      });
      if (_tabController.index == 1) {
        _scrollToBottom();
      }
    } else {
      setState(() => _isLoadingLogFiles = true);
    }

    // Load the full file in background (includes older lines from before this session)
    try {
      final result = await _logService.readTodayLogAsync(maxLines: 1000);
      final heartbeat = await _logService.readHeartbeat();

      if (mounted) {
        setState(() {
          _logLines = result.lines;
          _totalLogLines = result.totalLines;
          _logsTruncated = result.truncated;
          _heartbeat = heartbeat;
          _isLoadingLogFiles = false;
        });
        if (_tabController.index == 1) {
          _scrollToBottom();
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          // Keep in-memory lines on error instead of clearing
          if (_logLines.isEmpty) {
            _logLines = [];
            _totalLogLines = 0;
            _logsTruncated = false;
          }
          _heartbeat = null;
          _isLoadingLogFiles = false;
        });
      }
    }
  }

  Future<void> _loadCrashLogs() async {
    try {
      await _crashService.removeOldCrashLogs();
      final logs = await _crashService.readAllCrashLogs() ?? await _logService.readCrashLog();
      if (mounted) {
        setState(() {
          _crashLogs = logs;
          _expandedCrashCards.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _crashLogs = null);
      }
    }
  }

  /// Get filtered log lines
  List<String> _getFilteredLines() {
    if (_filterText.isEmpty) return _logLines;
    final lowerFilter = _filterText.toLowerCase();
    return _logLines.where((line) => line.toLowerCase().contains(lowerFilter)).toList();
  }

  /// Count formal crash reports only (=== CRASH REPORT ===)
  int _countFormalCrashReports(String? crashLogs) {
    if (crashLogs == null || crashLogs.trim().isEmpty) return 0;
    return '=== CRASH REPORT ==='.allMatches(crashLogs).length;
  }

  /// Extract only formal crash reports from crash logs
  String? _extractFormalCrashReports(String? crashLogs) {
    if (crashLogs == null || crashLogs.trim().isEmpty) return null;

    final buffer = StringBuffer();
    const startMarker = '=== CRASH REPORT ===';
    const endMarker = '=== END CRASH REPORT ===';

    int searchStart = 0;
    while (true) {
      final startIndex = crashLogs.indexOf(startMarker, searchStart);
      if (startIndex == -1) break;

      final endIndex = crashLogs.indexOf(endMarker, startIndex);
      if (endIndex == -1) {
        buffer.writeln(crashLogs.substring(startIndex).trim());
        break;
      }

      final crashReport = crashLogs.substring(startIndex, endIndex + endMarker.length);
      buffer.writeln(crashReport.trim());
      buffer.writeln();

      searchStart = endIndex + endMarker.length;
    }

    final result = buffer.toString().trim();
    return result.isEmpty ? null : result;
  }

  void _togglePause() {
    setState(() => _isPaused = !_isPaused);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isPaused ? _i18n.t('log_paused') : _i18n.t('log_resumed')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _clearLog() {
    _logService.clear();
    setState(() {
      _logLines = [];
      _totalLogLines = 0;
      _logsTruncated = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('log_cleared')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _clearCrashLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Crash Logs?'),
        content: const Text('This will delete all crash logs. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await _crashService.clearAllCrashLogs();
    await _loadCrashLogs();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crash logs cleared')),
      );
    }
  }

  void _copyToClipboard(String text, String successMessage) {
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(successMessage),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _copyAllLogs() {
    final logs = _getFilteredLines().join('\n');
    _copyToClipboard(logs, _i18n.t('log_copied_to_clipboard'));
  }

  void _copyExceptions() {
    final buffer = StringBuffer();

    if (_logLines.isNotEmpty) {
      buffer.writeln('=== TODAY\'S LOG ===');
      buffer.writeln(_logLines.join('\n'));
      buffer.writeln();
    }

    if (_crashLogs != null && _crashLogs!.isNotEmpty) {
      buffer.writeln(_crashLogs);
    }

    if (buffer.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No logs to copy')),
      );
      return;
    }

    _copyToClipboard(buffer.toString(), 'Logs copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('app_type_log')),
        actions: [
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: _isPaused ? _i18n.t('resume') : _i18n.t('pause'),
            onPressed: _togglePause,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (value) {
              switch (value) {
                case 'refresh':
                  _loadLogFiles();
                  break;
                case 'clear_log':
                  _clearLog();
                  break;
                case 'copy_all':
                  _copyAllLogs();
                  break;
                case 'copy_exceptions':
                  _copyExceptions();
                  break;
                case 'clear_crashes':
                  _clearCrashLogs();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'clear_log',
                child: ListTile(
                  leading: Icon(Icons.clear_all),
                  title: Text('Clear Log'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'copy_all',
                child: ListTile(
                  leading: Icon(Icons.copy),
                  title: Text('Copy All Logs'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'copy_exceptions',
                child: ListTile(
                  leading: Icon(Icons.bug_report),
                  title: Text('Copy Exceptions'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'clear_crashes',
                child: ListTile(
                  leading: Icon(Icons.delete_forever, color: Colors.red),
                  title: Text('Clear Crash Logs'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Crashes', icon: Icon(Icons.bug_report)),
            Tab(text: 'All', icon: Icon(Icons.list)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _filterController,
              decoration: InputDecoration(
                hintText: _i18n.t('filter_logs'),
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                suffixIcon: _filterText.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filterText = '');
                        },
                      )
                    : null,
              ),
              onChanged: (value) {
                setState(() => _filterText = value);
              },
            ),
          ),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCrashPanel(),
                _buildLogPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build the "All" log panel with efficient ListView.builder
  Widget _buildLogPanel() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final filteredLines = _getFilteredLines();
    final lineCount = filteredLines.length;

    if (_isLoadingLogFiles) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            border: Border(
              bottom: BorderSide(color: Colors.blue.withValues(alpha: 0.3)),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.article_outlined, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _filterText.isEmpty ? 'Today\'s Log' : 'Today\'s Log (filtered)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (_logsTruncated)
                      Text(
                        'Showing last 1000 of $_totalLogLines lines',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$lineCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy Today\'s Log',
                onPressed: lineCount > 0
                    ? () => _copyToClipboard(filteredLines.join('\n'), 'Today\'s log copied')
                    : null,
              ),
            ],
          ),
        ),
        // Log lines with ListView.builder for performance
        Expanded(
          child: lineCount > 0
              ? Container(
                  color: isDark ? Colors.black : Colors.grey[100],
                  child: ListView.builder(
                    controller: _logScrollController,
                    itemCount: filteredLines.length,
                    itemBuilder: (context, index) {
                      final line = filteredLines[index];
                      return _buildLogLine(line, isDark);
                    },
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.article_outlined,
                        size: 48,
                        color: Colors.grey,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _filterText.isEmpty ? 'No logs yet' : 'No matching logs',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// Build a single log line widget - minimal parsing for performance
  Widget _buildLogLine(String line, bool isDark) {
    // Quick level detection for coloring
    Color textColor = isDark ? Colors.grey[300]! : Colors.grey[800]!;

    if (line.contains('[ERROR]')) {
      textColor = Colors.red;
    } else if (line.contains('[WARN')) {
      textColor = Colors.orange;
    } else if (line.contains('[DEBUG]')) {
      textColor = Colors.grey;
    }

    return InkWell(
      onLongPress: () => _copyToClipboard(line, 'Line copied'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Text(
          line,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.3,
            color: textColor,
          ),
        ),
      ),
    );
  }

  /// Parse raw crash logs into a list of structured maps, sorted most recent first.
  List<Map<String, String>> _parseCrashReports(String? crashLogs) {
    if (crashLogs == null || crashLogs.trim().isEmpty) return [];

    final reports = <Map<String, String>>[];
    const startMarker = '=== CRASH REPORT ===';
    const endMarker = '=== END CRASH REPORT ===';

    int searchStart = 0;
    while (true) {
      final startIndex = crashLogs.indexOf(startMarker, searchStart);
      if (startIndex == -1) break;

      final endIndex = crashLogs.indexOf(endMarker, startIndex);
      final String rawBlock;
      if (endIndex == -1) {
        rawBlock = crashLogs.substring(startIndex).trim();
        searchStart = crashLogs.length;
      } else {
        rawBlock = crashLogs.substring(startIndex, endIndex + endMarker.length).trim();
        searchStart = endIndex + endMarker.length;
      }

      final map = <String, String>{'raw': rawBlock};

      // Parse key-value fields from the block
      for (final line in rawBlock.split('\n')) {
        if (line.startsWith('Timestamp: ')) {
          map['timestamp'] = line.substring('Timestamp: '.length).trim();
        } else if (line.startsWith('Type: ')) {
          map['type'] = line.substring('Type: '.length).trim();
        } else if (line.startsWith('App Version: ')) {
          map['version'] = line.substring('App Version: '.length).trim();
        } else if (line.startsWith('Platform: ')) {
          map['platform'] = line.substring('Platform: '.length).trim();
        } else if (line.startsWith('Error: ')) {
          map['error'] = line.substring('Error: '.length).trim();
        }
      }

      // Extract stack trace (everything between "Stack Trace:" and end marker)
      final stIndex = rawBlock.indexOf('Stack Trace:\n');
      if (stIndex != -1) {
        final stStart = stIndex + 'Stack Trace:\n'.length;
        final stEnd = rawBlock.indexOf(endMarker);
        if (stEnd != -1) {
          map['stackTrace'] = rawBlock.substring(stStart, stEnd).trim();
        } else {
          map['stackTrace'] = rawBlock.substring(stStart).trim();
        }
      }

      reports.add(map);
    }

    // Sort most recent first by timestamp
    reports.sort((a, b) {
      final ta = a['timestamp'] ?? '';
      final tb = b['timestamp'] ?? '';
      return tb.compareTo(ta);
    });

    return reports;
  }

  /// Format an ISO timestamp into a human-readable string (e.g. "Feb 3, 2025 at 15:30").
  String _formatCrashTimestamp(String isoTimestamp) {
    try {
      final dt = DateTime.parse(isoTimestamp);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      final month = months[dt.month - 1];
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$month ${dt.day}, ${dt.year} at $hour:$minute';
    } catch (_) {
      return isoTimestamp;
    }
  }

  /// Compute a relative time string (e.g. "2 days ago", "just now").
  String _relativeCrashTime(String isoTimestamp) {
    try {
      final dt = DateTime.parse(isoTimestamp);
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inSeconds < 60) return 'just now';
      if (diff.inMinutes < 60) {
        final m = diff.inMinutes;
        return '$m ${m == 1 ? 'minute' : 'minutes'} ago';
      }
      if (diff.inHours < 24) {
        final h = diff.inHours;
        return '$h ${h == 1 ? 'hour' : 'hours'} ago';
      }
      final d = diff.inDays;
      if (d < 30) return '$d ${d == 1 ? 'day' : 'days'} ago';
      if (d < 365) {
        final months = d ~/ 30;
        return '$months ${months == 1 ? 'month' : 'months'} ago';
      }
      final years = d ~/ 365;
      return '$years ${years == 1 ? 'year' : 'years'} ago';
    } catch (_) {
      return '';
    }
  }

  /// Build the crash panel with individual crash cards.
  Widget _buildCrashPanel() {
    final formalCrashReports = _extractFormalCrashReports(_crashLogs);
    final hasCrashLogs = formalCrashReports != null && formalCrashReports.isNotEmpty;
    final crashCount = _countFormalCrashReports(_crashLogs);
    final parsedCrashes = _parseCrashReports(_crashLogs);

    if (_isLoadingLogFiles && _crashLogs == null) {
      _loadCrashLogs();
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Header row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              const Icon(Icons.bug_report, color: Colors.red),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Crash Reports',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy All'),
                onPressed: _copyExceptions,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Copy these logs and share them to help fix issues.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Summary bar with count, copy-all, delete
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.report_problem, color: Colors.red),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Crash Reports',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$crashCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy Crash Reports',
                  onPressed: hasCrashLogs
                      ? () => _copyToClipboard(formalCrashReports, 'Crash reports copied')
                      : null,
                ),
                if (hasCrashLogs)
                  IconButton(
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    tooltip: 'Delete crash logs',
                    onPressed: _clearCrashLogs,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Crash cards list
        Expanded(
          child: parsedCrashes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.check_circle_outline, size: 48, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No crash reports', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _crashScrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: parsedCrashes.length,
                  itemBuilder: (context, index) =>
                      _buildCrashCard(parsedCrashes[index], index),
                ),
        ),
      ],
    );
  }

  /// Build an individual crash report card.
  Widget _buildCrashCard(Map<String, String> crash, int index) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final timestamp = crash['timestamp'] ?? '';
    final type = crash['type'] ?? 'Unknown';
    final version = crash['version'] ?? '';
    final platform = crash['platform'] ?? '';
    final error = crash['error'] ?? '';
    final stackTrace = crash['stackTrace'] ?? '';
    final raw = crash['raw'] ?? '';
    final isExpanded = _expandedCrashCards.contains(index);

    final formattedDate = timestamp.isNotEmpty ? _formatCrashTimestamp(timestamp) : 'Unknown time';
    final relativeTime = timestamp.isNotEmpty ? _relativeCrashTime(timestamp) : '';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date/time row
            Row(
              children: [
                Icon(Icons.access_time, size: 18, color: Colors.red[300]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: formattedDate,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        if (relativeTime.isNotEmpty)
                          TextSpan(
                            text: '  ($relativeTime)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Type + version + platform
            Wrap(
              spacing: 12,
              children: [
                if (type.isNotEmpty)
                  Text(type, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                if (version.isNotEmpty)
                  Text('v$version', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                if (platform.isNotEmpty)
                  Text(platform, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
            const SizedBox(height: 8),
            // Error text
            if (error.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black : Colors.grey[100],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  error,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            // Expandable stack trace
            if (stackTrace.isNotEmpty) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedCrashCards.remove(index);
                    } else {
                      _expandedCrashCards.add(index);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isExpanded ? 'Hide stack trace' : 'Show stack trace',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ),
              if (isExpanded)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.black : Colors.grey[100],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    stackTrace,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            // Action buttons row
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                  onPressed: () => _copyToClipboard(raw, 'Crash report copied'),
                ),
                if (!kIsWeb && Platform.isAndroid)
                  TextButton.icon(
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('Share'),
                    onPressed: () => Share.share(raw),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
