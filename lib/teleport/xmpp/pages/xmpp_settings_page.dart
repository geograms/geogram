/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP settings page — add/edit/remove server configs, connect/disconnect.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/i18n_service.dart';
import '../xmpp_service.dart';
import '../xmpp_client.dart';
import '../models/xmpp_server_config.dart';
import '../widgets/xmpp_room_list.dart';
import '../../../services/xmpp_server_stub.dart' if (dart.library.io) '../../../services/xmpp_server.dart';

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
        title: Text(I18nService().t('xmpp_settings_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: I18nService().t('xmpp_register_account_tooltip'),
            onPressed: () => _showRegisterSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: I18nService().t('xmpp_add_server_tooltip'),
            onPressed: () => _showAddServerSheet(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Connected / configured servers
          if (servers.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                I18nService().t('xmpp_my_servers_label'),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ...servers.map((s) => _buildServerCard(s, theme)),
            const Divider(height: 24),
          ],
          // Public server presets — always visible
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              I18nService().t('xmpp_public_servers_label'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              I18nService().t('xmpp_public_servers_desc'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: XmppServerConfig.presets.map((preset) {
                final alreadyAdded = servers.any((s) => s.host == preset.host);
                return GestureDetector(
                  onLongPress: () => _showRegisterSheet(context, preselectedHost: preset.host),
                  child: ActionChip(
                    avatar: alreadyAdded
                        ? Icon(Icons.check, size: 16, color: Colors.green.shade400)
                        : null,
                    label: Text(preset.name),
                    onPressed: () => _browseRooms(context, preset),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
        ],
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
                            I18nService().t('xmpp_autojoin_label', params: [config.autoJoinRooms.join(', ')]),
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
                    label: Text(connected ? I18nService().t('xmpp_disconnect_btn') : I18nService().t('xmpp_connect_btn')),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: I18nService().t('xmpp_account_details_tooltip'),
                    onPressed: () => _showAccountDetails(context, config),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    tooltip: I18nService().t('xmpp_edit_tooltip'),
                    onPressed: () => _showEditServerSheet(context, config),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    tooltip: I18nService().t('xmpp_remove_tooltip'),
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

  void _showAccountDetails(BuildContext context, XmppServerConfig config) {
    bool showPassword = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.account_circle, size: 24),
                const SizedBox(width: 12),
                Expanded(child: Text(config.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow(theme, I18nService().t('xmpp_server_label'), '${config.host}:${config.port}'),
                  _detailRow(theme, I18nService().t('xmpp_jid_label'), config.jid ?? 'Not set'),
                  _detailRow(
                    theme,
                    I18nService().t('xmpp_password_label'),
                    showPassword
                        ? (config.password ?? 'Not set')
                        : (config.password != null ? '\u2022' * 12 : 'Not set'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            showPassword ? Icons.visibility_off : Icons.visibility,
                            size: 18,
                          ),
                          onPressed: () => setDialogState(() => showPassword = !showPassword),
                          tooltip: showPassword ? I18nService().t('xmpp_hide_password') : I18nService().t('xmpp_show_password'),
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(4),
                        ),
                        if (config.password != null)
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: config.password!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(I18nService().t('xmpp_password_copied')),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                            tooltip: I18nService().t('xmpp_copy_btn'),
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.all(4),
                          ),
                      ],
                    ),
                  ),
                  _detailRow(theme, I18nService().t('xmpp_conference_label'), config.derivedConferenceService),
                  _detailRow(theme, I18nService().t('xmpp_tls_label_detail'), config.directTls ? I18nService().t('xmpp_direct_tls_label') : I18nService().t('xmpp_starttls_label')),
                  _detailRow(theme, I18nService().t('xmpp_autoconnect_label'), config.autoConnect ? I18nService().t('yes') : I18nService().t('no')),
                  if (config.autoJoinRooms.isNotEmpty)
                    _detailRow(theme, I18nService().t('xmpp_autojoin_label', params: ['']).split(':').first.trim(), config.autoJoinRooms.join(', ')),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(I18nService().t('close')),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _detailRow(ThemeData theme, String label, String value, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  void _browseRooms(BuildContext context, XmppServerConfig preset) {
    final xmpp = XmppService();
    // Find the first connected server to use as the connection for S2S discovery
    final connectedServer = xmpp.servers.where((s) => xmpp.isConnected(s.id)).firstOrNull;
    if (connectedServer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(I18nService().t('xmpp_connect_to_server_first')),
          action: SnackBarAction(
            label: I18nService().t('xmpp_register_btn'),
            onPressed: () => _showRegisterSheet(context, preselectedHost: preset.host),
          ),
        ),
      );
      return;
    }
    final confService = preset.conferenceService ?? 'conference.${preset.host}';
    xmpp.discoverRoomsOnService(connectedServer.id, confService);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XmppRoomBrowserPage(
          serverId: connectedServer.id,
          confService: confService,
        ),
      ),
    );
  }

  void _showRegisterSheet(BuildContext context, {String? preselectedHost}) {
    final usernameCtl = TextEditingController();
    final stationServer = XmppServer.instance;
    String? selectedHost = preselectedHost ?? (stationServer != null ? 'localhost' : null);
    bool registering = false;
    String? statusMessage;
    bool success = false;
    String? registeredJid;
    String? registeredPassword;

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
                    I18nService().t('xmpp_register_new_account_title'),
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    I18nService().t('xmpp_register_desc'),
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    I18nService().t('xmpp_server_label'),
                    style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // Station server option (shown first when available)
                      if (stationServer != null)
                        ChoiceChip(
                          label: Text(I18nService().t('xmpp_station_server_label', params: [stationServer.domain])),
                          selected: selectedHost == 'localhost',
                          avatar: const Icon(Icons.home, size: 16),
                          onSelected: registering
                              ? null
                              : (v) {
                                  setSheetState(() {
                                    selectedHost = v ? 'localhost' : null;
                                    statusMessage = null;
                                    success = false;
                                  });
                                },
                        ),
                      ...XmppServerConfig.presets.map((preset) {
                        final isSelected = selectedHost == preset.host;
                        return ChoiceChip(
                          label: Text(preset.name),
                          selected: isSelected,
                          onSelected: registering
                              ? null
                              : (v) {
                                  setSheetState(() {
                                    selectedHost = v ? preset.host : null;
                                    statusMessage = null;
                                    success = false;
                                  });
                                },
                        );
                      }),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: usernameCtl,
                    decoration: InputDecoration(
                      labelText: I18nService().t('xmpp_username_label'),
                      hintText: I18nService().t('xmpp_username_hint'),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    enabled: !registering,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    I18nService().t('xmpp_password_auto_desc'),
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  if (statusMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: success
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            statusMessage!,
                            style: TextStyle(
                              color: success ? Colors.green : Colors.red.shade300,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (success && registeredJid != null) ...[
                            const SizedBox(height: 8),
                            SelectableText(I18nService().t('xmpp_registered_jid', params: [registeredJid!])),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: SelectableText(I18nService().t('xmpp_registered_password', params: [registeredPassword ?? ''])),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 18),
                                  onPressed: () {
                                    Clipboard.setData(
                                      ClipboardData(text: registeredPassword ?? ''),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(I18nService().t('xmpp_password_copied')),
                                        duration: const Duration(seconds: 1),
                                      ),
                                    );
                                  },
                                  tooltip: I18nService().t('xmpp_copy_btn'),
                                  constraints: const BoxConstraints(),
                                  padding: const EdgeInsets.all(4),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(success ? I18nService().t('ok') : I18nService().t('cancel')),
                      ),
                      if (!success) ...[
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: registering || selectedHost == null
                              ? null
                              : () async {
                                  setSheetState(() {
                                    registering = true;
                                    statusMessage = I18nService().t('xmpp_registering_msg', params: [selectedHost!]);
                                    success = false;
                                  });
                                  final user = usernameCtl.text.trim().isNotEmpty
                                      ? usernameCtl.text.trim()
                                      : null;
                                  final preset = XmppServerConfig.presets.where((p) => p.host == selectedHost).firstOrNull;
                                  final result = await XmppService().registerAccount(
                                    host: selectedHost!,
                                    username: user,
                                    port: preset?.port ?? 5223,
                                    directTls: preset?.directTls ?? true,
                                    conferenceService: preset?.conferenceService,
                                  );
                                  if (!ctx.mounted) return;
                                  setSheetState(() {
                                    registering = false;
                                    success = result['success'] == true;
                                    if (success) {
                                      registeredJid = result['jid'] as String?;
                                      registeredPassword = result['password'] as String?;
                                      statusMessage = I18nService().t('xmpp_account_created');
                                    } else {
                                      statusMessage = result['error'] as String? ?? 'Registration failed';
                                    }
                                  });
                                },
                          child: registering
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(I18nService().t('xmpp_register_btn')),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).then((_) {
      usernameCtl.dispose();
    });
  }

  void _confirmRemove(BuildContext context, XmppServerConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18nService().t('xmpp_remove_server_title')),
        content: Text(I18nService().t('xmpp_remove_server_confirm', params: [config.name, config.host])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(I18nService().t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              XmppService().removeServer(config.id);
              Navigator.pop(ctx);
            },
            child: Text(I18nService().t('xmpp_remove_btn')),
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
                    existing != null ? I18nService().t('xmpp_edit_server_title') : I18nService().t('xmpp_add_server_title'),
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
                      labelText: I18nService().t('xmpp_name_label'),
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
                    decoration: InputDecoration(
                      labelText: I18nService().t('xmpp_password_label'),
                      border: const OutlineInputBorder(),
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
                    title: Text(I18nService().t('xmpp_direct_tls_label')),
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
                    title: Text(I18nService().t('xmpp_autoconnect_label')),
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
      jidCtl.dispose();
      passCtl.dispose();
      confCtl.dispose();
      autoJoinCtl.dispose();
    });
  }
}
