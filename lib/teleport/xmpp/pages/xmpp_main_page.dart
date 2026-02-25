/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP main page — server list with connection status,
 * tap to view rooms for a server.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../xmpp_service.dart';
import '../models/xmpp_server_config.dart';
import '../widgets/xmpp_room_list.dart';
import 'xmpp_settings_page.dart';

class XmppMainPage extends StatefulWidget {
  final String appPath;

  const XmppMainPage({super.key, required this.appPath});

  @override
  State<XmppMainPage> createState() => _XmppMainPageState();
}

class _XmppMainPageState extends State<XmppMainPage> {
  StreamSubscription<XmppEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    XmppService().addUiObserver();
    _eventSub = XmppService().events.listen((event) {
      if (!mounted) return;
      setState(() {});

      if (event.type == XmppEventType.error) {
        final config = XmppService().servers
            .where((s) => s.id == event.serverId)
            .firstOrNull;
        final name = config?.name ?? event.serverId ?? 'XMPP';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$name: ${event.data}'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }

      if (event.type == XmppEventType.connected) {
        final config = XmppService().servers
            .where((s) => s.id == event.serverId)
            .firstOrNull;
        final name = config?.name ?? event.serverId ?? 'XMPP';
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
    XmppService().removeUiObserver();
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final xmpp = XmppService();
    final servers = xmpp.servers;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('XMPP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'XMPP Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => XmppSettingsPage(appPath: widget.appPath),
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
            Icons.message,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            'No XMPP servers configured',
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
                  builder: (_) => XmppSettingsPage(appPath: widget.appPath),
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

  Widget _buildServerTile(XmppServerConfig config, ThemeData theme) {
    final xmpp = XmppService();
    final connected = xmpp.isConnected(config.id);
    final rooms = xmpp.getRooms(config.id);
    final nick = xmpp.currentNick(config.id) ?? '';
    final isConnecting = !connected && xmpp.isClientActive(config.id);
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
                    color: const Color(0xFFFF6600).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Stack(
                    children: [
                      const Center(
                        child: Icon(
                          Icons.message,
                          size: 24,
                          color: Color(0xFFFF6600),
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
                            ? '$nick — ${rooms.length} room${rooms.length == 1 ? '' : 's'}'
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
                // On/off switch
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

  void _toggleServer(XmppServerConfig config, bool on) {
    final xmpp = XmppService();
    final updated = config.copyWith(autoConnect: on);
    xmpp.updateServer(updated);

    if (on) {
      if (!xmpp.isConnected(config.id) && !xmpp.isClientActive(config.id)) {
        xmpp.connect(config.id);
      }
    } else {
      if (xmpp.isConnected(config.id) || xmpp.isClientActive(config.id)) {
        xmpp.disconnectServer(config.id);
      }
    }
  }

  void _openServer(XmppServerConfig config) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ServerRoomsPage(serverId: config.id),
      ),
    );
  }
}

/// Sub-page: room list for a specific server.
class _ServerRoomsPage extends StatefulWidget {
  final String serverId;

  const _ServerRoomsPage({required this.serverId});

  @override
  State<_ServerRoomsPage> createState() => _ServerRoomsPageState();
}

class _ServerRoomsPageState extends State<_ServerRoomsPage> {
  StreamSubscription<XmppEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _eventSub = XmppService().events.listen((event) {
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
    final xmpp = XmppService();
    final config = xmpp.servers.where((s) => s.id == widget.serverId).firstOrNull;
    final connected = xmpp.isConnected(widget.serverId);
    final isConnecting = !connected && xmpp.isClientActive(widget.serverId);

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
          IconButton(
            icon: Icon(connected ? Icons.link_off : Icons.link),
            tooltip: connected ? 'Disconnect' : 'Connect',
            onPressed: () {
              if (connected) {
                xmpp.disconnectServer(widget.serverId);
              } else {
                xmpp.connect(widget.serverId);
              }
            },
          ),
        ],
      ),
      body: XmppRoomList(serverId: widget.serverId),
    );
  }
}
