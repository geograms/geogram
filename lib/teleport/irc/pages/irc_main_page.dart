/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC main page — server list with connection status,
 * tap to view channels for a server.
 * Auto-connects when tapping an offline server.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../irc_service.dart';
import '../models/irc_server_config.dart';
import '../widgets/irc_channel_list.dart';
import 'irc_settings_page.dart';

class IrcMainPage extends StatefulWidget {
  final String appPath;

  const IrcMainPage({super.key, required this.appPath});

  @override
  State<IrcMainPage> createState() => _IrcMainPageState();
}

class _IrcMainPageState extends State<IrcMainPage> {
  StreamSubscription<IrcEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    IrcService().addUiObserver();
    _eventSub = IrcService().events.listen((event) {
      if (!mounted) return;
      setState(() {});

      // Show errors as snackbar
      if (event.type == IrcEventType.error) {
        final config = IrcService().servers
            .where((s) => s.id == event.serverId)
            .firstOrNull;
        final name = config?.name ?? event.serverId ?? 'IRC';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$name: ${event.data}'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }

      // Show connection success
      if (event.type == IrcEventType.connected) {
        final config = IrcService().servers
            .where((s) => s.id == event.serverId)
            .firstOrNull;
        final name = config?.name ?? event.serverId ?? 'IRC';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to $name'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    IrcService().removeUiObserver();
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final irc = IrcService();
    final servers = irc.servers;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('IRC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'IRC Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => IrcSettingsPage(appPath: widget.appPath),
                ),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
          ),
        ],
      ),
      body: servers.isEmpty
          ? _buildEmptyState(theme)
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: servers.length,
              itemBuilder: (context, index) =>
                  _buildServerTile(servers[index], theme),
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            'No IRC servers configured',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add a server to get started',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => IrcSettingsPage(appPath: widget.appPath),
                ),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Add Server'),
          ),
        ],
      ),
    );
  }

  Widget _buildServerTile(IrcServerConfig config, ThemeData theme) {
    final irc = IrcService();
    final connected = irc.isConnected(config.id);
    final channels = irc.getChannels(config.id);
    final nick = irc.currentNick(config.id) ?? '';
    final isConnecting = !connected && irc.isClientActive(config.id);
    final isOn = connected || isConnecting || config.autoConnect;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openServer(config),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Status indicator
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Stack(
                    children: [
                      const Center(
                        child: Icon(
                          Icons.terminal,
                          size: 24,
                          color: Color(0xFF4CAF50),
                        ),
                      ),
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: connected
                                ? Colors.green
                                : isConnecting
                                    ? Colors.orange
                                    : Colors.grey,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.surfaceContainerLow,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        connected
                            ? '$nick — ${channels.length} channel${channels.length == 1 ? '' : 's'}'
                            : isConnecting
                                ? 'Connecting...'
                                : '${config.host}:${config.port}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isConnecting
                              ? Colors.orange
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // On/off switch — toggles autoConnect + connects/disconnects
                Switch(
                  value: isOn,
                  activeColor: Colors.green,
                  onChanged: (value) => _toggleServer(config, value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleServer(IrcServerConfig config, bool on) {
    final irc = IrcService();
    // Update autoConnect in config
    final updated = config.copyWith(autoConnect: on);
    irc.updateServer(updated);

    if (on) {
      // Connect if not already
      if (!irc.isConnected(config.id) && !irc.isClientActive(config.id)) {
        irc.connect(config.id);
      }
    } else {
      // Disconnect
      if (irc.isConnected(config.id) || irc.isClientActive(config.id)) {
        irc.disconnect(config.id);
      }
    }
  }

  void _openServer(IrcServerConfig config) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ServerChannelsPage(serverId: config.id),
      ),
    );
  }
}

/// Sub-page: channel list for a specific server.
class _ServerChannelsPage extends StatefulWidget {
  final String serverId;

  const _ServerChannelsPage({required this.serverId});

  @override
  State<_ServerChannelsPage> createState() => _ServerChannelsPageState();
}

class _ServerChannelsPageState extends State<_ServerChannelsPage> {
  StreamSubscription<IrcEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _eventSub = IrcService().events.listen((event) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final irc = IrcService();
    final config = irc.servers.where((s) => s.id == widget.serverId).firstOrNull;
    final connected = irc.isConnected(widget.serverId);
    final isConnecting = !connected && irc.isClientActive(widget.serverId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(config?.name ?? widget.serverId),
            if (isConnecting)
              Text(
                'Connecting...',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                ),
              )
            else if (!connected)
              Text(
                'Offline',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          // Connect/disconnect button
          IconButton(
            icon: Icon(connected ? Icons.link_off : Icons.link),
            tooltip: connected ? 'Disconnect' : 'Connect',
            onPressed: () {
              if (connected) {
                irc.disconnect(widget.serverId);
              } else {
                irc.connect(widget.serverId);
              }
            },
          ),
        ],
      ),
      body: IrcChannelList(serverId: widget.serverId),
    );
  }
}
