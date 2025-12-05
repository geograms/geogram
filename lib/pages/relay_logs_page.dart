/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../services/relay_node_service.dart';

/// Log types for relay
enum RelayLogType {
  connections,
  moderation,
  sync,
}

/// A log entry
class RelayLogEntry {
  final DateTime timestamp;
  final String message;
  final String? level;
  final String? source;

  RelayLogEntry({
    required this.timestamp,
    required this.message,
    this.level,
    this.source,
  });

  factory RelayLogEntry.parse(String line) {
    // Parse log lines in format: [2025-11-26 15:30:00] [INFO] [source] message
    final timestampMatch = RegExp(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]').firstMatch(line);
    final levelMatch = RegExp(r'\[(INFO|WARN|ERROR|DEBUG)\]').firstMatch(line);
    final sourceMatch = RegExp(r'\[(\w+)\]').allMatches(line).skip(2).firstOrNull;

    DateTime timestamp;
    try {
      timestamp = timestampMatch != null
          ? DateTime.parse(timestampMatch.group(1)!.replaceFirst(' ', 'T'))
          : DateTime.now();
    } catch (_) {
      timestamp = DateTime.now();
    }

    return RelayLogEntry(
      timestamp: timestamp,
      message: line,
      level: levelMatch?.group(1),
      source: sourceMatch?.group(1),
    );
  }
}

/// Page for viewing relay logs
class RelayLogsPage extends StatefulWidget {
  const RelayLogsPage({super.key});

  @override
  State<RelayLogsPage> createState() => _RelayLogsPageState();
}

class _RelayLogsPageState extends State<RelayLogsPage> with SingleTickerProviderStateMixin {
  final RelayNodeService _relayNodeService = RelayNodeService();

  late TabController _tabController;
  List<RelayLogEntry> _connectionLogs = [];
  List<RelayLogEntry> _moderationLogs = [];
  List<RelayLogEntry> _syncLogs = [];
  bool _isLoading = true;
  String? _error;

  // Filter
  String _searchQuery = '';
  String? _levelFilter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadLogs();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final relayDir = await _relayNodeService.getRelayDirectory();
      final logsDir = Directory(path.join(relayDir.path, 'logs'));

      if (!await logsDir.exists()) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      // Load each log type
      _connectionLogs = await _loadLogFile(path.join(logsDir.path, 'connections.log'));
      _moderationLogs = await _loadLogFile(path.join(logsDir.path, 'moderation.log'));
      _syncLogs = await _loadLogFile(path.join(logsDir.path, 'sync.log'));

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<List<RelayLogEntry>> _loadLogFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return [];
    }

    try {
      final lines = await file.readAsLines();
      return lines
          .where((line) => line.isNotEmpty)
          .map((line) => RelayLogEntry.parse(line))
          .toList()
          .reversed
          .toList(); // Most recent first
    } catch (e) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Relay Logs'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadLogs,
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.filter_list),
            tooltip: 'Filter by level',
            onSelected: (value) {
              setState(() {
                _levelFilter = value == 'all' ? null : value;
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'all', child: Text('All levels')),
              PopupMenuItem(value: 'ERROR', child: Text('Errors only')),
              PopupMenuItem(value: 'WARN', child: Text('Warnings')),
              PopupMenuItem(value: 'INFO', child: Text('Info')),
              PopupMenuItem(value: 'DEBUG', child: Text('Debug')),
            ],
          ),
          IconButton(
            icon: Icon(Icons.delete_outline),
            onPressed: _clearLogs,
            tooltip: 'Clear logs',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Connections', icon: Icon(Icons.device_hub)),
            Tab(text: 'Moderation', icon: Icon(Icons.shield)),
            Tab(text: 'Sync', icon: Icon(Icons.sync)),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search logs...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.toLowerCase();
                });
              },
            ),
          ),
          if (_levelFilter != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Chip(
                label: Text('Filter: $_levelFilter'),
                onDeleted: () => setState(() => _levelFilter = null),
              ),
            ),
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('Error: $_error'))
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildLogList(_connectionLogs, 'No connection logs yet'),
                          _buildLogList(_moderationLogs, 'No moderation logs yet'),
                          _buildLogList(_syncLogs, 'No sync logs yet'),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogList(List<RelayLogEntry> logs, String emptyMessage) {
    final filtered = logs.where((log) {
      if (_searchQuery.isNotEmpty && !log.message.toLowerCase().contains(_searchQuery)) {
        return false;
      }
      if (_levelFilter != null && log.level != _levelFilter) {
        return false;
      }
      return true;
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.article_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text(emptyMessage, style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final entry = filtered[index];
        return _buildLogEntry(entry);
      },
    );
  }

  Widget _buildLogEntry(RelayLogEntry entry) {
    Color levelColor;
    IconData levelIcon;

    switch (entry.level) {
      case 'ERROR':
        levelColor = Colors.red;
        levelIcon = Icons.error;
        break;
      case 'WARN':
        levelColor = Colors.orange;
        levelIcon = Icons.warning;
        break;
      case 'DEBUG':
        levelColor = Colors.grey;
        levelIcon = Icons.bug_report;
        break;
      default:
        levelColor = Colors.blue;
        levelIcon = Icons.info;
    }

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        leading: Icon(levelIcon, color: levelColor, size: 20),
        title: Text(
          entry.message,
          style: TextStyle(fontFamily: 'monospace', fontSize: 12),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          _formatTimestamp(entry.timestamp),
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
        onTap: () => _showLogDetail(entry),
        dense: true,
      ),
    );
  }

  void _showLogDetail(RelayLogEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Log Entry'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Time:', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_formatTimestamp(entry.timestamp)),
              SizedBox(height: 8),
              if (entry.level != null) ...[
                Text('Level:', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(entry.level!),
                SizedBox(height: 8),
              ],
              if (entry.source != null) ...[
                Text('Source:', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(entry.source!),
                SizedBox(height: 8),
              ],
              Text('Message:', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(
                entry.message,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear Logs?'),
        content: Text('This will delete all relay logs. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Clear'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final relayDir = await _relayNodeService.getRelayDirectory();
      final logsDir = Directory(path.join(relayDir.path, 'logs'));

      if (await logsDir.exists()) {
        for (final file in logsDir.listSync()) {
          if (file is File && file.path.endsWith('.log')) {
            await file.writeAsString('');
          }
        }
      }

      await _loadLogs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logs cleared')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error clearing logs: $e')),
        );
      }
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
  }
}
