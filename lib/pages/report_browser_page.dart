/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/report.dart';
import '../services/report_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import 'report_detail_page.dart';
import 'report_settings_page.dart';

/// Report browser page with list and map views
class ReportBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;

  const ReportBrowserPage({
    super.key,
    required this.collectionPath,
    required this.collectionTitle,
  });

  @override
  State<ReportBrowserPage> createState() => _ReportBrowserPageState();
}

class _ReportBrowserPageState extends State<ReportBrowserPage> {
  final ReportService _reportService = ReportService();
  final ProfileService _profileService = ProfileService();
  final TextEditingController _searchController = TextEditingController();

  List<Report> _allReports = [];
  List<Report> _filteredReports = [];
  ReportSeverity? _filterSeverity;
  ReportStatus? _filterStatus;
  bool _isLoading = true;
  int _sortMode = 0; // 0: date desc, 1: severity, 2: distance

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterReports);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _reportService.initializeCollection(widget.collectionPath);
    await _loadReports();
  }

  Future<void> _loadReports() async {
    setState(() => _isLoading = true);

    _allReports = await _reportService.loadReports();

    setState(() {
      _filteredReports = _allReports;
      _isLoading = false;
    });

    _filterReports();
  }

  void _filterReports() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredReports = _allReports.where((report) {
        // Filter by severity
        if (_filterSeverity != null && report.severity != _filterSeverity) {
          return false;
        }

        // Filter by status
        if (_filterStatus != null && report.status != _filterStatus) {
          return false;
        }

        // Filter by search query
        if (query.isEmpty) return true;

        final title = report.getTitle('EN').toLowerCase();
        final description = report.getDescription('EN').toLowerCase();
        final type = report.type.toLowerCase();
        return title.contains(query) || description.contains(query) || type.contains(query);
      }).toList();

      // Sort reports
      switch (_sortMode) {
        case 0: // Date descending
          _filteredReports.sort((a, b) => b.dateTime.compareTo(a.dateTime));
          break;
        case 1: // Severity
          _filteredReports.sort((a, b) {
            final severityOrder = {
              ReportSeverity.emergency: 0,
              ReportSeverity.urgent: 1,
              ReportSeverity.attention: 2,
              ReportSeverity.info: 3,
            };
            return (severityOrder[a.severity] ?? 3).compareTo(severityOrder[b.severity] ?? 3);
          });
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collectionTitle),
        actions: [
          // Filter by severity
          PopupMenuButton<ReportSeverity?>(
            icon: Icon(_filterSeverity == null ? Icons.filter_alt_outlined : Icons.filter_alt),
            tooltip: 'Filter by severity',
            onSelected: (severity) {
              setState(() {
                _filterSeverity = severity;
                _filterReports();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: const Text('All Severities'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: ReportSeverity.emergency,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.emergency),
                    const SizedBox(width: 8),
                    const Text('Emergency'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: ReportSeverity.urgent,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.urgent),
                    const SizedBox(width: 8),
                    const Text('Urgent'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: ReportSeverity.attention,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.attention),
                    const SizedBox(width: 8),
                    const Text('Attention'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: ReportSeverity.info,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.info),
                    const SizedBox(width: 8),
                    const Text('Info'),
                  ],
                ),
              ),
            ],
          ),
          // Filter by status
          PopupMenuButton<ReportStatus?>(
            icon: Icon(_filterStatus == null ? Icons.swap_vert : Icons.check_circle),
            tooltip: 'Filter by status',
            onSelected: (status) {
              setState(() {
                _filterStatus = status;
                _filterReports();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: const Text('All Statuses'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: ReportStatus.open,
                child: const Text('Open'),
              ),
              PopupMenuItem(
                value: ReportStatus.inProgress,
                child: const Text('In Progress'),
              ),
              PopupMenuItem(
                value: ReportStatus.resolved,
                child: const Text('Resolved'),
              ),
              PopupMenuItem(
                value: ReportStatus.closed,
                child: const Text('Closed'),
              ),
            ],
          ),
          // Sort
          PopupMenuButton<int>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort by',
            onSelected: (mode) {
              setState(() {
                _sortMode = mode;
                _filterReports();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 0,
                child: Row(
                  children: [
                    if (_sortMode == 0) const Icon(Icons.check, size: 16),
                    if (_sortMode == 0) const SizedBox(width: 8),
                    const Text('Date (Newest)'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 1,
                child: Row(
                  children: [
                    if (_sortMode == 1) const Icon(Icons.check, size: 16),
                    if (_sortMode == 1) const SizedBox(width: 8),
                    const Text('Severity'),
                  ],
                ),
              ),
            ],
          ),
          // Settings
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ReportSettingsPage(
                    collectionPath: widget.collectionPath,
                  ),
                ),
              );
              _loadReports();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search reports...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),

                // Active filters display
                if (_filterSeverity != null || _filterStatus != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (_filterSeverity != null)
                          Chip(
                            label: Text(_filterSeverity!.name),
                            onDeleted: () {
                              setState(() {
                                _filterSeverity = null;
                                _filterReports();
                              });
                            },
                          ),
                        if (_filterStatus != null)
                          Chip(
                            label: Text(_filterStatus!.name),
                            onDeleted: () {
                              setState(() {
                                _filterStatus = null;
                                _filterReports();
                              });
                            },
                          ),
                      ],
                    ),
                  ),

                // Reports list
                Expanded(
                  child: _filteredReports.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.report_outlined, size: 64, color: theme.colorScheme.primary),
                              const SizedBox(height: 16),
                              Text(
                                _allReports.isEmpty ? 'No reports yet' : 'No matching reports',
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _allReports.isEmpty
                                    ? 'Create your first report'
                                    : 'Try adjusting your filters',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredReports.length,
                          itemBuilder: (context, index) {
                            final report = _filteredReports[index];
                            return _buildReportCard(report, theme);
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createReport,
        icon: const Icon(Icons.add),
        label: const Text('New Report'),
      ),
    );
  }

  Widget _buildReportCard(Report report, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: () => _openReport(report),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildSeverityBadge(report.severity),
                  const SizedBox(width: 8),
                  _buildStatusBadge(report.status),
                  const Spacer(),
                  Text(
                    _formatDate(report.dateTime),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                report.getTitle('EN'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                report.type,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                report.getDescription('EN'),
                style: theme.textTheme.bodyMedium,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      report.address ?? '${report.latitude.toStringAsFixed(4)}, ${report.longitude.toStringAsFixed(4)}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (report.verificationCount > 0) ...[
                    const SizedBox(width: 16),
                    Icon(Icons.verified, size: 16, color: Colors.green),
                    const SizedBox(width: 4),
                    Text(
                      '${report.verificationCount}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (report.subscriberCount > 0) ...[
                    const SizedBox(width: 16),
                    Icon(Icons.people, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      '${report.subscriberCount}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeverityBadge(ReportSeverity severity) {
    Color color;
    IconData icon;

    switch (severity) {
      case ReportSeverity.emergency:
        color = Colors.red;
        icon = Icons.emergency;
        break;
      case ReportSeverity.urgent:
        color = Colors.orange;
        icon = Icons.warning;
        break;
      case ReportSeverity.attention:
        color = Colors.yellow.shade700;
        icon = Icons.report_problem;
        break;
      case ReportSeverity.info:
        color = Colors.blue;
        icon = Icons.info;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            severity.name.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(ReportStatus status) {
    Color color;

    switch (status) {
      case ReportStatus.open:
        color = Colors.grey;
        break;
      case ReportStatus.inProgress:
        color = Colors.blue;
        break;
      case ReportStatus.resolved:
        color = Colors.green;
        break;
      case ReportStatus.closed:
        color = Colors.grey.shade700;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        status.name.replaceAll(RegExp(r'([A-Z])'), ' \$1').trim().toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        if (diff.inMinutes == 0) {
          return 'Just now';
        }
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
  }

  void _openReport(Report report) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReportDetailPage(
          collectionPath: widget.collectionPath,
          report: report,
        ),
      ),
    ).then((_) => _loadReports());
  }

  void _createReport() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReportDetailPage(
          collectionPath: widget.collectionPath,
        ),
      ),
    ).then((_) => _loadReports());
  }
}
