/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC settings page — add/edit/remove server configs, connect/disconnect.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../irc_service.dart';
import '../models/irc_server_config.dart';

class IrcSettingsPage extends StatefulWidget {
  final String appPath;

  const IrcSettingsPage({super.key, required this.appPath});

  @override
  State<IrcSettingsPage> createState() => _IrcSettingsPageState();
}

class _IrcSettingsPageState extends State<IrcSettingsPage> {
  StreamSubscription<IrcEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    IrcService().addUiObserver();
    _eventSub = IrcService().events.listen((event) {
      if (mounted) setState(() {});

      // Show connection errors
      if (event.type == IrcEventType.error && mounted) {
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
        title: Text(I18nService().t('irc_settings_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: I18nService().t('irc_add_server_btn'),
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
                    I18nService().t('irc_no_servers_configured'),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _showAddServerSheet(context),
                    icon: const Icon(Icons.add),
                    label: Text(I18nService().t('irc_add_server_btn')),
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

  Widget _buildServerCard(IrcServerConfig config, ThemeData theme) {
    final irc = IrcService();
    final connected = irc.isConnected(config.id);

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
                          '${config.host}:${config.port}${config.useTls ? ' (TLS)' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (config.autoJoinChannels.isNotEmpty)
                          Text(
                            'Auto-join: ${config.autoJoinChannels.join(', ')}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Status dot
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
                  // Connect/disconnect
                  OutlinedButton.icon(
                    onPressed: () {
                      if (connected) {
                        irc.disconnect(config.id);
                      } else {
                        irc.connect(config.id);
                      }
                    },
                    icon: Icon(
                      connected ? Icons.link_off : Icons.link,
                      size: 18,
                    ),
                    label: Text(connected ? I18nService().t('irc_disconnect_btn') : I18nService().t('irc_connect_btn')),
                  ),
                  const SizedBox(width: 8),
                  // Edit
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    tooltip: 'Edit',
                    onPressed: () => _showEditServerSheet(context, config),
                  ),
                  // Delete
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

  void _confirmRemove(BuildContext context, IrcServerConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18nService().t('irc_remove_server_title')),
        content: Text(I18nService().t('irc_remove_server_confirm', params: [config.name, config.host])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(I18nService().t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              IrcService().removeServer(config.id);
              Navigator.pop(ctx);
            },
            child: Text(I18nService().t('irc_remove_btn')),
          ),
        ],
      ),
    );
  }

  void _showAddServerSheet(BuildContext context) {
    _showServerForm(context, null);
  }

  void _showEditServerSheet(BuildContext context, IrcServerConfig config) {
    _showServerForm(context, config);
  }

  void _showServerForm(BuildContext context, IrcServerConfig? existing) {
    final nameCtl = TextEditingController(text: existing?.name ?? '');
    final hostCtl = TextEditingController(text: existing?.host ?? '');
    final portCtl = TextEditingController(
        text: existing?.port.toString() ?? '6697');
    final passCtl = TextEditingController(text: existing?.password ?? '');
    final autoJoinCtl = TextEditingController(
        text: existing?.autoJoinChannels.join(', ') ?? '');
    bool useTls = existing?.useTls ?? true;
    bool autoConnect = existing?.autoConnect ?? false;
    String? nameError;
    String? hostError;

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
                    existing != null ? I18nService().t('irc_edit_server_title') : I18nService().t('irc_add_server_btn'),
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  // Preset buttons
                  if (existing == null) ...[
                    Text(
                      I18nService().t('irc_quick_add_label'),
                      style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: IrcServerConfig.presets.map((preset) {
                        return ActionChip(
                          label: Text(preset.name),
                          onPressed: () {
                            setSheetState(() {
                              nameCtl.text = preset.name;
                              hostCtl.text = preset.host;
                              portCtl.text = preset.port.toString();
                              useTls = preset.useTls;
                              // Clear validation errors
                              nameError = null;
                              hostError = null;
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
                      labelText: I18nService().t('irc_name_label'),
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
                            labelText: I18nService().t('irc_host_label'),
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
                          decoration: InputDecoration(
                            labelText: I18nService().t('irc_port_label'),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtl,
                    decoration: InputDecoration(
                      labelText: I18nService().t('irc_nickserv_password_label'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: autoJoinCtl,
                    decoration: InputDecoration(
                      labelText: I18nService().t('irc_autojoin_channels_label'),
                      hintText: I18nService().t('irc_channel_example'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: Text(I18nService().t('irc_tls_label')),
                    value: useTls,
                    onChanged: (v) => setSheetState(() {
                      useTls = v;
                      if (v && portCtl.text == '6667') portCtl.text = '6697';
                      if (!v && portCtl.text == '6697') portCtl.text = '6667';
                    }),
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: Text(I18nService().t('irc_autoconnect_label')),
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
                        child: Text(I18nService().t('cancel')),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          final name = nameCtl.text.trim();
                          final host = hostCtl.text.trim();

                          // Validate with error messages
                          bool hasError = false;
                          if (name.isEmpty) {
                            nameError = 'Name is required';
                            hasError = true;
                          }
                          if (host.isEmpty) {
                            hostError = 'Host is required';
                            hasError = true;
                          }
                          if (hasError) {
                            setSheetState(() {});
                            return;
                          }

                          final port =
                              int.tryParse(portCtl.text.trim()) ?? (useTls ? 6697 : 6667);
                          final pass = passCtl.text.trim();
                          final autoJoin = autoJoinCtl.text
                              .split(',')
                              .map((s) => s.trim())
                              .where((s) => s.isNotEmpty)
                              .toList();

                          final id = existing?.id ??
                              '${host}_${DateTime.now().millisecondsSinceEpoch}';
                          final config = IrcServerConfig(
                            id: id,
                            name: name,
                            host: host,
                            port: port,
                            useTls: useTls,
                            password: pass.isEmpty ? null : pass,
                            autoJoinChannels: autoJoin,
                            autoConnect: autoConnect,
                          );

                          if (existing != null) {
                            IrcService().updateServer(config);
                          } else {
                            IrcService().addServer(config);
                          }
                          Navigator.pop(ctx);
                        },
                        child: Text(existing != null ? I18nService().t('save') : I18nService().t('add')),
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
      passCtl.dispose();
      autoJoinCtl.dispose();
    });
  }
}
