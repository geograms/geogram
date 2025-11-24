/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/report.dart';
import '../models/report_update.dart';
import '../services/report_service.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';

/// Page for viewing and editing report details
class ReportDetailPage extends StatefulWidget {
  final String collectionPath;
  final Report? report; // null for new report

  const ReportDetailPage({
    super.key,
    required this.collectionPath,
    this.report,
  });

  @override
  State<ReportDetailPage> createState() => _ReportDetailPageState();
}

class _ReportDetailPageState extends State<ReportDetailPage> {
  final ReportService _reportService = ReportService();
  final ProfileService _profileService = ProfileService();

  late bool _isNew;
  late bool _isEditing;
  Report? _report;
  List<ReportUpdate> _updates = [];
  bool _isLoading = false;
  String? _currentUserNpub;

  // Form controllers
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  final _addressController = TextEditingController();
  final _contactController = TextEditingController();
  final _typeController = TextEditingController();

  ReportSeverity _selectedSeverity = ReportSeverity.attention;
  ReportStatus _selectedStatus = ReportStatus.open;

  @override
  void initState() {
    super.initState();
    _isNew = widget.report == null;
    _isEditing = _isNew;
    _report = widget.report;

    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;

    if (_report != null) {
      _titleController.text = _report!.getTitle('EN');
      _descriptionController.text = _report!.getDescription('EN');
      _latitudeController.text = _report!.latitude.toString();
      _longitudeController.text = _report!.longitude.toString();
      _addressController.text = _report!.address ?? '';
      _contactController.text = _report!.contact ?? '';
      _typeController.text = _report!.type;
      _selectedSeverity = _report!.severity;
      _selectedStatus = _report!.status;

      _loadUpdates();
    } else {
      _typeController.text = 'other';
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    _addressController.dispose();
    _contactController.dispose();
    _typeController.dispose();
    super.dispose();
  }

  Future<void> _loadUpdates() async {
    if (_report == null) return;

    setState(() => _isLoading = true);

    try {
      _updates = await _reportService.loadUpdates(_report!.folderName);
    } catch (e) {
      LogService().log('ReportDetailPage: Error loading updates: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _save() async {
    // Validate
    if (_titleController.text.trim().isEmpty) {
      _showError('Title is required');
      return;
    }

    if (_descriptionController.text.trim().isEmpty) {
      _showError('Description is required');
      return;
    }

    final lat = double.tryParse(_latitudeController.text);
    final lon = double.tryParse(_longitudeController.text);

    if (lat == null || lon == null) {
      _showError('Valid coordinates are required');
      return;
    }

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      _showError('Coordinates out of range');
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_isNew) {
        // Create new report
        final profile = _profileService.getProfile();
        if (profile.callsign.isEmpty) {
          _showError('Please set up your profile first');
          setState(() => _isLoading = false);
          return;
        }

        _report = await _reportService.createReport(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          author: profile.callsign,
          latitude: lat,
          longitude: lon,
          severity: _selectedSeverity,
          type: _typeController.text.trim(),
          address: _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
          contact: _contactController.text.trim().isNotEmpty ? _contactController.text.trim() : null,
        );

        _showSuccess('Report created');
        setState(() {
          _isNew = false;
          _isEditing = false;
        });
      } else if (_report != null) {
        // Update existing report
        final updated = _report!.copyWith(
          titles: {'EN': _titleController.text.trim()},
          descriptions: {'EN': _descriptionController.text.trim()},
          latitude: lat,
          longitude: lon,
          severity: _selectedSeverity,
          status: _selectedStatus,
          type: _typeController.text.trim(),
          address: _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
          contact: _contactController.text.trim().isNotEmpty ? _contactController.text.trim() : null,
        );

        await _reportService.saveReport(updated);
        _report = updated;

        _showSuccess('Report updated');
        setState(() {
          _isEditing = false;
        });
      }
    } catch (e) {
      _showError('Failed to save: $e');
      LogService().log('ReportDetailPage: Error saving: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _toggleSubscription() async {
    if (_report == null || _currentUserNpub == null || _currentUserNpub!.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (_report!.isSubscribed(_currentUserNpub!)) {
        await _reportService.unsubscribe(_report!.folderName, _currentUserNpub!);
        _showSuccess('Unsubscribed');
      } else {
        await _reportService.subscribe(_report!.folderName, _currentUserNpub!);
        _showSuccess('Subscribed');
      }

      // Reload report
      _report = await _reportService.loadReport(_report!.folderName);
      setState(() {});
    } catch (e) {
      _showError('Failed to toggle subscription: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _verify() async {
    if (_report == null || _currentUserNpub == null || _currentUserNpub!.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await _reportService.verify(_report!.folderName, _currentUserNpub!);
      _showSuccess('Verified');

      // Reload report
      _report = await _reportService.loadReport(_report!.folderName);
      setState(() {});
    } catch (e) {
      _showError('Failed to verify: $e');
    }

    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = _report == null || (_currentUserNpub != null && _report!.isAdmin(_currentUserNpub!));

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New Report' : 'Report Details'),
        actions: [
          if (!_isNew && !_isEditing && canEdit)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                setState(() {
                  _isEditing = true;
                });
              },
            ),
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _isLoading ? null : _save,
            ),
        ],
      ),
      body: _isLoading && _report == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status badges
                  if (_report != null) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildSeverityChip(_report!.severity),
                        _buildStatusChip(_report!.status),
                        if (_report!.verificationCount > 0)
                          Chip(
                            avatar: const Icon(Icons.verified, color: Colors.green, size: 16),
                            label: Text('${_report!.verificationCount} verifications'),
                          ),
                        if (_report!.isExpired)
                          Chip(
                            avatar: const Icon(Icons.warning, color: Colors.orange, size: 16),
                            label: const Text('Expired'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Title
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title *',
                      hintText: 'Brief description of the issue',
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),

                  // Description
                  TextField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description *',
                      hintText: 'Detailed description of the issue',
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                    maxLines: 8,
                  ),
                  const SizedBox(height: 16),

                  // Coordinates
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _latitudeController,
                          decoration: const InputDecoration(
                            labelText: 'Latitude *',
                            border: OutlineInputBorder(),
                          ),
                          enabled: _isEditing,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _longitudeController,
                          decoration: const InputDecoration(
                            labelText: 'Longitude *',
                            border: OutlineInputBorder(),
                          ),
                          enabled: _isEditing,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Address
                  TextField(
                    controller: _addressController,
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: 'Street address or location description',
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                  ),
                  const SizedBox(height: 16),

                  // Type
                  TextField(
                    controller: _typeController,
                    decoration: const InputDecoration(
                      labelText: 'Type *',
                      hintText: 'e.g., infrastructure-broken, vandalism, hazard',
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                  ),
                  const SizedBox(height: 16),

                  // Severity
                  DropdownButtonFormField<ReportSeverity>(
                    initialValue: _selectedSeverity,
                    decoration: const InputDecoration(
                      labelText: 'Severity *',
                      border: OutlineInputBorder(),
                    ),
                    items: ReportSeverity.values.map((severity) {
                      return DropdownMenuItem(
                        value: severity,
                        child: Text(severity.name),
                      );
                    }).toList(),
                    onChanged: _isEditing
                        ? (value) {
                            if (value != null) {
                              setState(() {
                                _selectedSeverity = value;
                              });
                            }
                          }
                        : null,
                  ),
                  const SizedBox(height: 16),

                  // Status (only for existing reports)
                  if (!_isNew) ...[
                    DropdownButtonFormField<ReportStatus>(
                      initialValue: _selectedStatus,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      items: ReportStatus.values.map((status) {
                        return DropdownMenuItem(
                          value: status,
                          child: Text(status.name),
                        );
                      }).toList(),
                      onChanged: _isEditing && canEdit
                          ? (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedStatus = value;
                                });
                              }
                            }
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Contact
                  TextField(
                    controller: _contactController,
                    decoration: const InputDecoration(
                      labelText: 'Contact',
                      hintText: 'Contact information or notes',
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                  ),
                  const SizedBox(height: 24),

                  // Actions (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    const SizedBox(height: 16),
                    Text(
                      'Actions',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_currentUserNpub != null && _currentUserNpub!.isNotEmpty) ...[
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _toggleSubscription,
                            icon: Icon(_report!.isSubscribed(_currentUserNpub!)
                                ? Icons.notifications_off
                                : Icons.notifications),
                            label: Text(_report!.isSubscribed(_currentUserNpub!)
                                ? 'Unsubscribe'
                                : 'Subscribe'),
                          ),
                          if (!_report!.verifiedBy.contains(_currentUserNpub))
                            ElevatedButton.icon(
                              onPressed: _isLoading ? null : _verify,
                              icon: const Icon(Icons.verified),
                              label: const Text('Verify'),
                            ),
                        ],
                        ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                              text: '${_report!.latitude},${_report!.longitude}',
                            ));
                            _showSuccess('Coordinates copied');
                          },
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy Coords'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Updates section (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Updates',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${_updates.length}',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_updates.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('No updates yet'),
                        ),
                      )
                    else
                      ..._updates.map((update) => _buildUpdateCard(update, theme)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSeverityChip(ReportSeverity severity) {
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

    return Chip(
      avatar: Icon(icon, color: color, size: 16),
      label: Text(severity.name.toUpperCase()),
      backgroundColor: color.withOpacity(0.2),
    );
  }

  Widget _buildStatusChip(ReportStatus status) {
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

    return Chip(
      label: Text(status.name.replaceAll(RegExp(r'([A-Z])'), ' \$1').trim().toUpperCase()),
      backgroundColor: color.withOpacity(0.2),
    );
  }

  Widget _buildUpdateCard(ReportUpdate update, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.update, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    update.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'By ${update.author} • ${_formatUpdateDate(update.dateTime)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              update.content,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  String _formatUpdateDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
