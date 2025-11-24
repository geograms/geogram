/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/report_settings.dart';
import '../services/report_service.dart';
import '../services/log_service.dart';

/// Page for managing report collection settings
class ReportSettingsPage extends StatefulWidget {
  final String collectionPath;

  const ReportSettingsPage({
    super.key,
    required this.collectionPath,
  });

  @override
  State<ReportSettingsPage> createState() => _ReportSettingsPageState();
}

class _ReportSettingsPageState extends State<ReportSettingsPage> {
  final ReportService _reportService = ReportService();

  ReportSettings _settings = ReportSettings();
  bool _isLoading = false;

  final _defaultTtlController = TextEditingController();
  final _autoArchiveResolvedController = TextEditingController();
  final _minVerificationsController = TextEditingController();
  final _duplicateDistanceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _defaultTtlController.dispose();
    _autoArchiveResolvedController.dispose();
    _minVerificationsController.dispose();
    _duplicateDistanceController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);

    try {
      await _reportService.initializeCollection(widget.collectionPath);
      _settings = _reportService.getSettings();

      // Populate controllers
      _defaultTtlController.text = (_settings.defaultTtl ~/ 86400).toString(); // Convert to days
      _autoArchiveResolvedController.text = _settings.autoArchiveResolved.toString();
      _minVerificationsController.text = _settings.minVerifications.toString();
      _duplicateDistanceController.text = _settings.duplicateDistanceThreshold.toString();
    } catch (e) {
      LogService().log('ReportSettingsPage: Error loading settings: $e');
      _showError('Failed to load settings: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    // Validate inputs
    final defaultTtlDays = int.tryParse(_defaultTtlController.text);
    if (defaultTtlDays == null || defaultTtlDays < 0) {
      _showError('Invalid default TTL value');
      return;
    }

    final autoArchiveDays = int.tryParse(_autoArchiveResolvedController.text);
    if (autoArchiveDays == null || autoArchiveDays < 0) {
      _showError('Invalid auto-archive value');
      return;
    }

    final minVerifications = int.tryParse(_minVerificationsController.text);
    if (minVerifications == null || minVerifications < 1) {
      _showError('Invalid minimum verifications value');
      return;
    }

    final duplicateDistance = double.tryParse(_duplicateDistanceController.text);
    if (duplicateDistance == null || duplicateDistance <= 0) {
      _showError('Invalid duplicate distance value');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final updated = _settings.copyWith(
        defaultTtl: defaultTtlDays * 86400, // Convert days to seconds
        autoArchiveResolved: autoArchiveDays,
        minVerifications: minVerifications,
        duplicateDistanceThreshold: duplicateDistance,
      );

      await _reportService.saveSettings(updated);
      _settings = updated;

      _showSuccess('Settings saved successfully');
    } catch (e) {
      LogService().log('ReportSettingsPage: Error saving settings: $e');
      _showError('Failed to save settings: $e');
    }

    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Report Settings'),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSettings,
            tooltip: 'Save Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection(
            theme,
            'Report Lifecycle',
            [
              TextField(
                controller: _defaultTtlController,
                decoration: const InputDecoration(
                  labelText: 'Default TTL (days)',
                  hintText: 'Time before reports expire (0 for never)',
                  border: OutlineInputBorder(),
                  helperText: 'Default time-to-live for new reports',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _autoArchiveResolvedController,
                decoration: const InputDecoration(
                  labelText: 'Auto-archive resolved (days)',
                  hintText: 'Days after resolution to auto-archive',
                  border: OutlineInputBorder(),
                  helperText: 'Resolved reports will be archived after this period',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Show expired reports'),
                subtitle: const Text('Display expired reports in main view'),
                value: _settings.showExpired,
                onChanged: (value) {
                  setState(() {
                    _settings = _settings.copyWith(showExpired: value);
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSection(
            theme,
            'Verification System',
            [
              SwitchListTile(
                title: const Text('Enable verification'),
                subtitle: const Text('Allow users to verify reports'),
                value: _settings.enableVerification,
                onChanged: (value) {
                  setState(() {
                    _settings = _settings.copyWith(enableVerification: value);
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _minVerificationsController,
                decoration: const InputDecoration(
                  labelText: 'Minimum verifications',
                  hintText: 'Number of verifications for verified badge',
                  border: OutlineInputBorder(),
                  helperText: 'Required verifications to show verified badge',
                ),
                keyboardType: TextInputType.number,
                enabled: _settings.enableVerification,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSection(
            theme,
            'Duplicate Detection',
            [
              SwitchListTile(
                title: const Text('Enable duplicate detection'),
                subtitle: const Text('Detect and link similar nearby reports'),
                value: _settings.enableDuplicateDetection,
                onChanged: (value) {
                  setState(() {
                    _settings = _settings.copyWith(enableDuplicateDetection: value);
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _duplicateDistanceController,
                decoration: const InputDecoration(
                  labelText: 'Distance threshold (meters)',
                  hintText: 'Max distance for duplicate detection',
                  border: OutlineInputBorder(),
                  helperText: 'Reports within this distance may be duplicates',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                enabled: _settings.enableDuplicateDetection,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSection(
            theme,
            'Subscriptions',
            [
              SwitchListTile(
                title: const Text('Enable subscriptions'),
                subtitle: const Text('Allow users to subscribe to report updates'),
                value: _settings.enableSubscriptions,
                onChanged: (value) {
                  setState(() {
                    _settings = _settings.copyWith(enableSubscriptions: value);
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saveSettings,
            icon: const Icon(Icons.save),
            label: const Text('Save Settings'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.all(16),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSection(ThemeData theme, String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
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
