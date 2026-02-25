/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP settings page — add/edit/remove server configs, connect/disconnect.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../xmpp_service.dart';
import '../models/xmpp_server_config.dart';

class XmppSettingsPage extends StatefulWidget {
  final String appPath;

  const XmppSettingsPage({super.key, required this.appPath});

  @override
  State<XmppSettingsPage> createState() => _XmppSettingsPageState();
}

class _XmppSettingsPageState extends State<XmppSettingsPage> {
  StreamSubscription<XmppEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    XmppService().addUiObserver();
    _eventSub = XmppService().events.listen((event) {
      if (mounted) setState(() {});

      if (event.type == XmppEventType.error && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${event.serverId}: ${event.data}'),
            backgroundColor: Colors.red.shade700,
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
        title: const Text('XMPP Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Server',
            onPressed: () => _showAddServerSheet(context),
          ),
        ],
      ),
      body: servers.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No servers configured',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _showAddServerSheet(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Server'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: servers.length,
              itemBuilder: (context, index) =>
                  _buildServerCard(servers[index], theme),
            ),
    );
  }

  Widget _buildServerCard(XmppServerConfig config, ThemeData theme) {
    final xmpp = XmppService();
    final connected = xmpp.isConnected(config.id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
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
                          '${config.host}:${config.port}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (config.jid != null && config.jid!.isNotEmpty)
                          Text(
                            config.jid!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (config.autoJoinRooms.isNotEmpty)
                          Text(
                            'Auto-join: ${config.autoJoinRooms.join(', ')}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: connected ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      if (connected) {
                        xmpp.disconnectServer(config.id);
                      } else {
                        xmpp.connect(config.id);
                      }
                    },
                    icon: Icon(
                      connected ? Icons.link_off : Icons.link,
                      size: 18,
                    ),
                    label: Text(connected ? 'Disconnect' : 'Connect'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    tooltip: 'Edit',
                    onPressed: () => _showEditServerSheet(context, config),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => _confirmRemove(context, config),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmRemove(BuildContext context, XmppServerConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Server'),
        content: Text('Remove ${config.name} (${config.host})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              XmppService().removeServer(config.id);
              Navigator.pop(ctx);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _showAddServerSheet(BuildContext context) {
    _showServerForm(context, null);
  }

  void _showEditServerSheet(BuildContext context, XmppServerConfig config) {
    _showServerForm(context, config);
  }

  void _showServerForm(BuildContext context, XmppServerConfig? existing) {
    final nameCtl = TextEditingController(text: existing?.name ?? '');
    final hostCtl = TextEditingController(text: existing?.host ?? '');
    final portCtl = TextEditingController(
        text: existing?.port.toString() ?? '5222');
    final jidCtl = TextEditingController(text: existing?.jid ?? '');
    final passCtl = TextEditingController(text: existing?.password ?? '');
    final confCtl = TextEditingController(text: existing?.conferenceService ?? '');
    final autoJoinCtl = TextEditingController(
        text: existing?.autoJoinRooms.join(', ') ?? '');
    bool directTls = existing?.directTls ?? false;
    bool autoConnect = existing?.autoConnect ?? false;
    String? nameError;
    String? hostError;
    String? jidError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    existing != null ? 'Edit Server' : 'Add Server',
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  // Preset buttons
                  if (existing == null) ...[
                    Text(
                      'Quick Add',
                      style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: XmppServerConfig.presets.map((preset) {
                        return ActionChip(
                          label: Text(preset.name),
                          onPressed: () {
                            setSheetState(() {
                              nameCtl.text = preset.name;
                              hostCtl.text = preset.host;
                              portCtl.text = preset.port.toString();
                              confCtl.text = preset.conferenceService ?? '';
                              directTls = preset.directTls;
                              nameError = null;
                              hostError = null;
                              jidError = null;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Form fields
                  TextField(
                    controller: nameCtl,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: nameError,
                    ),
                    autofocus: existing == null,
                    onChanged: (_) {
                      if (nameError != null) setSheetState(() => nameError = null);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: hostCtl,
                          decoration: InputDecoration(
                            labelText: 'Host',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            errorText: hostError,
                          ),
                          onChanged: (_) {
                            if (hostError != null) setSheetState(() => hostError = null);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: portCtl,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: jidCtl,
                    decoration: InputDecoration(
                      labelText: 'JID (user@domain)',
                      hintText: 'username@${hostCtl.text.isNotEmpty ? hostCtl.text : 'server.com'}',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: jidError,
                    ),
                    onChanged: (_) {
                      if (jidError != null) setSheetState(() => jidError = null);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtl,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confCtl,
                    decoration: InputDecoration(
                      labelText: 'Conference Service (optional)',
                      hintText: 'conference.${hostCtl.text.isNotEmpty ? hostCtl.text : 'server.com'}',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: autoJoinCtl,
                    decoration: const InputDecoration(
                      labelText: 'Auto-join rooms (comma-separated)',
                      hintText: 'room1@conference.server, room2@conference.server',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Direct TLS'),
                    subtitle: const Text('Use TLS from the start (port 5223)'),
                    value: directTls,
                    onChanged: (v) => setSheetState(() {
                      directTls = v;
                      if (v && portCtl.text == '5222') portCtl.text = '5223';
                      if (!v && portCtl.text == '5223') portCtl.text = '5222';
                    }),
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Auto-connect'),
                    value: autoConnect,
                    onChanged: (v) => setSheetState(() => autoConnect = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          final name = nameCtl.text.trim();
                          final host = hostCtl.text.trim();
                          final jid = jidCtl.text.trim();

                          bool hasError = false;
                          if (name.isEmpty) {
                            nameError = 'Name is required';
                            hasError = true;
                          }
                          if (host.isEmpty) {
                            hostError = 'Host is required';
                            hasError = true;
                          }
                          if (jid.isEmpty || !jid.contains('@')) {
                            jidError = 'Valid JID required (user@domain)';
                            hasError = true;
                          }
                          if (hasError) {
                            setSheetState(() {});
                            return;
                          }

                          final port =
                              int.tryParse(portCtl.text.trim()) ?? 5222;
                          final pass = passCtl.text.trim();
                          final conf = confCtl.text.trim();
                          final autoJoin = autoJoinCtl.text
                              .split(',')
                              .map((s) => s.trim())
                              .where((s) => s.isNotEmpty)
                              .toList();

                          final id = existing?.id ??
                              '${host}_${DateTime.now().millisecondsSinceEpoch}';
                          final config = XmppServerConfig(
                            id: id,
                            name: name,
                            host: host,
                            port: port,
                            directTls: directTls,
                            jid: jid,
                            password: pass.isEmpty ? null : pass,
                            conferenceService: conf.isEmpty ? null : conf,
                            autoJoinRooms: autoJoin,
                            autoConnect: autoConnect,
                          );

                          if (existing != null) {
                            XmppService().updateServer(config);
                          } else {
                            XmppService().addServer(config);
                          }
                          Navigator.pop(ctx);
                        },
                        child: Text(existing != null ? 'Save' : 'Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).then((_) {
      nameCtl.dispose();
      hostCtl.dispose();
      portCtl.dispose();
      jidCtl.dispose();
      passCtl.dispose();
      confCtl.dispose();
      autoJoinCtl.dispose();
    });
  }
}
