/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal bridge settings — linked device info, connection status,
 * unlink device, cache management.
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/profile_storage.dart';
import '../signal_service.dart';
import '../signal_storage_service.dart';

class SignalSettingsPage extends StatefulWidget {
  final String appPath;

  const SignalSettingsPage({super.key, required this.appPath});

  @override
  State<SignalSettingsPage> createState() => _SignalSettingsPageState();
}

class _SignalSettingsPageState extends State<SignalSettingsPage> {
  Map<String, dynamic>? _config;
  Map<String, dynamic>? _status;
  bool _loading = true;
  String? _cacheSize;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) return;

      final scoped = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      final storage = SignalStorageService.fromScoped(scoped);

      final config = await storage.readConfig();
      final status = await storage.readStatus();

      setState(() {
        _config = config;
        _status = status;
        _loading = false;
      });

      _computeCacheSize();
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _computeCacheSize() async {
    final cache = SignalService().cacheService;
    if (cache == null) return;

    final cacheDir = Directory(cache.cacheDirAbsolutePath);
    if (!cacheDir.existsSync()) return;

    int totalBytes = 0;
    try {
      for (final f in cacheDir.listSync().whereType<File>()) {
        totalBytes += f.lengthSync();
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _cacheSize = _formatSize(totalBytes));
    }
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _disconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Signal?'),
        content: const Text(
          'This will disconnect the Signal bridge. '
          'Your linked device will be kept so you can reconnect later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    await SignalService().disconnect();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signal disconnected')),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _unlinkDevice() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlink this device?'),
        content: const Text(
          'This will unlink this device from your Signal account. '
          'You will need to scan a new QR code to use Signal again. '
          'Your message cache will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final authService = SignalService().authService;
      await authService?.unlinkDevice();
      await SignalService().disconnect();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device unlinked')),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to unlink: $e')),
        );
      }
    }
  }

  Future<void> _destroyBridge() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Signal Bridge?'),
        content: const Text(
          'This will remove the Signal bridge completely, '
          'including your device link and all cached data. '
          'You will need to set up the bridge again to use Signal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    await SignalService().destroy();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signal bridge removed')),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _clearCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear message cache?'),
        content: const Text(
          'This will delete all locally cached messages. '
          'Messages will be re-fetched from Signal when you open a conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    final cache = SignalService().cacheService;
    if (cache != null) {
      cache.clearCache();
      _computeCacheSize();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = SignalService().isRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Signal Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Connection status
                Card(
                  child: ListTile(
                    leading: Icon(
                      isRunning ? Icons.cloud_done : Icons.cloud_off,
                      color:
                          isRunning ? Colors.green : theme.colorScheme.error,
                    ),
                    title: Text(isRunning ? 'Connected' : 'Disconnected'),
                    subtitle: _status != null
                        ? Text(_status!['state'] as String? ?? 'unknown')
                        : null,
                  ),
                ),
                const SizedBox(height: 16),

                // Device info
                if (_config != null) ...[
                  Text('Device Info',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: const Text('Device Name'),
                          subtitle: Text(
                            _config!['device_name'] as String? ??
                                'Geogram Desktop',
                          ),
                        ),
                        if (_status?['last_auth'] != null)
                          ListTile(
                            title: const Text('Last Authenticated'),
                            subtitle: Text(
                              _status!['last_auth'] as String,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Cache management
                Text('Cache',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.storage),
                        title: const Text('Message Cache'),
                        subtitle: Text(_cacheSize ?? 'Calculating...'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.cleaning_services),
                        title: const Text('Clear Cache'),
                        subtitle:
                            const Text('Delete locally cached messages'),
                        onTap: _clearCache,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Actions
                if (isRunning)
                  OutlinedButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _unlinkDevice,
                  icon: Icon(Icons.devices,
                      color: theme.colorScheme.error),
                  label: Text('Unlink Device',
                      style: TextStyle(color: theme.colorScheme.error)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _destroyBridge,
                  icon: Icon(Icons.delete_forever,
                      color: theme.colorScheme.error),
                  label: Text('Remove Bridge',
                      style: TextStyle(color: theme.colorScheme.error)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
    );
  }
}
