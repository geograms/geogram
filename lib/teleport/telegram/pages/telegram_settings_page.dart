/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Telegram bridge settings — view credentials, disconnect, status info.
 */

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/profile_storage.dart';
import '../telegram_service.dart';
import '../telegram_storage_service.dart';

class TelegramSettingsPage extends StatefulWidget {
  final String appPath;

  const TelegramSettingsPage({super.key, required this.appPath});

  @override
  State<TelegramSettingsPage> createState() => _TelegramSettingsPageState();
}

class _TelegramSettingsPageState extends State<TelegramSettingsPage> {
  Map<String, dynamic>? _config;
  Map<String, dynamic>? _status;
  bool _loading = true;

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
      final storage = TelegramStorageService.fromScoped(scoped);

      final config = await storage.readConfig();
      final status = await storage.readStatus();

      setState(() {
        _config = config;
        _status = status;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _disconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Telegram?'),
        content: const Text(
          'This will disconnect the Telegram bridge. '
          'Your credentials will be kept so you can reconnect later.',
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

    await TelegramService().disconnect();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Telegram disconnected')),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _destroyBridge() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Telegram Bridge?'),
        content: const Text(
          'This will remove the Telegram bridge completely, '
          'including your API credentials. You will need to set up '
          'the bridge again to use Telegram.',
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

    await TelegramService().destroy();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Telegram bridge removed')),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  String _maskApiHash(String hash) {
    if (hash.length <= 8) return '****';
    return '${hash.substring(0, 4)}...${hash.substring(hash.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = TelegramService().isRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Telegram Settings')),
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
                      color: isRunning ? Colors.green : theme.colorScheme.error,
                    ),
                    title: Text(isRunning ? 'Connected' : 'Disconnected'),
                    subtitle: _status != null
                        ? Text(_status!['state'] as String? ?? 'unknown')
                        : null,
                  ),
                ),
                const SizedBox(height: 16),

                // API credentials
                if (_config != null) ...[
                  Text('API Credentials',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: const Text('API ID'),
                          subtitle: Text('${_config!['api_id'] ?? 'Not set'}'),
                        ),
                        ListTile(
                          title: const Text('API Hash'),
                          subtitle: Text(
                            _config!['api_hash'] != null
                                ? _maskApiHash(
                                    _config!['api_hash'] as String)
                                : 'Not set',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Actions
                if (isRunning)
                  OutlinedButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
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
