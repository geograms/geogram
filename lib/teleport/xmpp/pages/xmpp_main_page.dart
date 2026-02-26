/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP main page — servers with inline room lists, grouped by domain.
 * Configured servers show connection status and toggle.
 * Federated servers (rooms accessed via S2S) show "via {server}" label.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../xmpp_service.dart';
import '../models/xmpp_room.dart';
import '../models/xmpp_server_config.dart';
import '../widgets/xmpp_room_list.dart';
import 'xmpp_settings_page.dart';
import 'xmpp_chat_page.dart';

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
        final config = XmppService()
            .servers
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
        final config = XmppService()
            .servers
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
          : _buildServerList(xmpp, servers, theme),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Server list with domain-grouped rooms
  // ---------------------------------------------------------------------------

  Widget _buildServerList(
      XmppService xmpp, List<XmppServerConfig> servers, ThemeData theme) {
    final groups = _buildGroups(xmpp, servers);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 80),
      itemCount: groups.length,
      itemBuilder: (context, index) =>
          _buildServerSection(groups[index], theme),
    );
  }

  // ---------------------------------------------------------------------------
  // Domain grouping — rooms grouped by their actual server, not connection
  // ---------------------------------------------------------------------------

  List<_ServerGroup> _buildGroups(
      XmppService xmpp, List<XmppServerConfig> servers) {
    // Map conference domain → configured server config
    final confToConfig = <String, XmppServerConfig>{};
    for (final config in servers) {
      confToConfig[config.derivedConferenceService] = config;
    }

    // Initialize groups for all configured servers (shown even with 0 rooms)
    final configuredGroups = <String, _ServerGroup>{};
    for (final config in servers) {
      configuredGroups[config.id] = _ServerGroup(
        domain: config.host,
        config: config,
        connectionServerId: config.id,
        confService: config.derivedConferenceService,
        rooms: [],
      );
    }

    // Federated groups (rooms on external servers accessed via S2S)
    final federatedGroups = <String, _ServerGroup>{};

    // Distribute all rooms into their correct group
    for (final config in servers) {
      final rooms = xmpp.getRooms(config.id);
      for (final room in rooms) {
        final confDomain = room.jid.split('@').last;
        final matchedConfig = confToConfig[confDomain];
        if (matchedConfig != null) {
          configuredGroups[matchedConfig.id]!.rooms.add(room);
        } else {
          // Federated room — group by parent domain
          final domain = _parentDomain(confDomain);
          federatedGroups
              .putIfAbsent(
                domain,
                () => _ServerGroup(
                  domain: domain,
                  config: null,
                  viaServerName: config.name,
                  connectionServerId: config.id,
                  confService: confDomain,
                  rooms: [],
                ),
              )
              .rooms
              .add(room);
        }
      }
    }

    // Sort rooms within each group
    for (final group in [
      ...configuredGroups.values,
      ...federatedGroups.values,
    ]) {
      _sortRooms(group.rooms);
    }

    return [
      ...configuredGroups.values,
      ...federatedGroups.values.toList()
        ..sort((a, b) => a.domain.compareTo(b.domain)),
    ];
  }

  static String _parentDomain(String confDomain) {
    final parts = confDomain.split('.');
    if (parts.length > 2) return parts.sublist(1).join('.');
    return confDomain;
  }

  static void _sortRooms(List<XmppRoom> rooms) {
    rooms.sort((a, b) {
      if (a.unreadCount > 0 && b.unreadCount == 0) return -1;
      if (a.unreadCount == 0 && b.unreadCount > 0) return 1;
      if (a.unreadCount > 0 && b.unreadCount > 0) {
        final cmp = b.unreadCount.compareTo(a.unreadCount);
        if (cmp != 0) return cmp;
      }
      final aTime = a.lastMessage?.timestamp;
      final bTime = b.lastMessage?.timestamp;
      if (aTime == null && bTime == null) return a.jid.compareTo(b.jid);
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
  }

  // ---------------------------------------------------------------------------
  // Server section (header + inline room tiles)
  // ---------------------------------------------------------------------------

  Widget _buildServerSection(_ServerGroup group, ThemeData theme) {
    final xmpp = XmppService();
    final connected = group.config != null
        ? xmpp.isConnected(group.config!.id)
        : xmpp.isConnected(group.connectionServerId);
    final isConnecting = group.config != null &&
        !connected &&
        xmpp.isClientActive(group.config!.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Server header
        _buildServerHeader(group, connected, isConnecting, theme),
        // Room tiles or empty hint
        if (group.rooms.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
            child: Text(
              group.isConfigured
                  ? (connected
                      ? 'No rooms joined'
                      : (isConnecting ? 'Connecting...' : 'Offline'))
                  : 'No rooms',
              style: theme.textTheme.bodySmall?.copyWith(
                color: isConnecting
                    ? Colors.orange
                    : theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          ...group.rooms
              .map((room) => _buildRoomTile(room, group, theme)),
        const Divider(height: 1, indent: 16, endIndent: 16),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildServerHeader(
    _ServerGroup group,
    bool connected,
    bool isConnecting,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
      child: Row(
        children: [
          // Status dot
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: group.isConfigured
                  ? (connected
                      ? Colors.green
                      : (isConnecting ? Colors.orange : Colors.grey))
                  : Colors.blue.shade400,
              shape: BoxShape.circle,
            ),
          ),
          // Server name + subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.domain,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (group.isFederated && group.viaServerName != null)
                  Text(
                    'via ${group.viaServerName}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.blue.shade400,
                    ),
                  ),
              ],
            ),
          ),
          // Browse rooms button (when connected or federated with active connection)
          if (connected || (group.isFederated && XmppService().isConnected(group.connectionServerId)))
            IconButton(
              icon: const Icon(Icons.explore, size: 20),
              tooltip: 'Browse rooms',
              onPressed: () => _browseRooms(group),
              visualDensity: VisualDensity.compact,
            ),
          // Connect toggle for configured servers
          if (group.isConfigured)
            Switch(
              value: connected || isConnecting || group.config!.autoConnect,
              activeColor: Colors.green,
              onChanged: (value) => _toggleServer(group.config!, value),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Room tile
  // ---------------------------------------------------------------------------

  Widget _buildRoomTile(XmppRoom room, _ServerGroup group, ThemeData theme) {
    final lastMsg = room.lastMessage;
    final hasUnread = room.unreadCount > 0;

    return InkWell(
      onTap: () => _openRoom(room),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Room avatar
            CircleAvatar(
              radius: 22,
              backgroundColor:
                  const Color(0xFFFF6600).withValues(alpha: 0.15),
              child: Text(
                _roomInitial(room),
                style: const TextStyle(
                  color: Color(0xFFFF6600),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Room name + last message
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name.isNotEmpty
                        ? room.name
                        : room.jid.split('@').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: hasUnread
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (lastMsg != null)
                    Text(
                      lastMsg.isSystemMessage
                          ? lastMsg.text
                          : '${lastMsg.sender}: ${lastMsg.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Text(
                      room.subject.isNotEmpty
                          ? room.subject
                          : '${room.occupants.length} occupant${room.occupants.length == 1 ? '' : 's'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Trailing: time + unread badge + occupant count
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (lastMsg != null)
                  Text(
                    _formatTime(lastMsg.timestamp),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: hasUnread
                          ? const Color(0xFFFF6600)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasUnread)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF6600),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${room.unreadCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    Icon(
                      Icons.people_outline,
                      size: 13,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${room.occupants.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _roomInitial(XmppRoom room) {
    final name =
        room.name.isNotEmpty ? room.name : room.jid.split('@').first;
    return name.isNotEmpty ? name[0].toUpperCase() : '#';
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

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

  void _browseRooms(_ServerGroup group) {
    final xmpp = XmppService();
    final serverId = group.connectionServerId;
    final confService = group.confService ?? '';

    if (!xmpp.isConnected(serverId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server not connected')),
      );
      return;
    }

    if (confService.isNotEmpty) {
      xmpp.discoverRoomsOnService(serverId, confService);
    } else {
      xmpp.discoverRooms(serverId);
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XmppRoomBrowserPage(
          serverId: serverId,
          confService: confService,
        ),
      ),
    );
  }

  void _openRoom(XmppRoom room) {
    XmppService().markRoomRead(room.serverConfigId, room.jid);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XmppChatPage(
          serverId: room.serverConfigId,
          roomJid: room.jid,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Time formatting
  // ---------------------------------------------------------------------------

  static String _formatTime(DateTime utcDate) {
    final local = utcDate.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(local.year, local.month, local.day);

    if (msgDay == today) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    final diff = today.difference(msgDay).inDays;
    if (diff == 1) return 'Yesterday';
    return '${local.month}/${local.day}';
  }
}

// ---------------------------------------------------------------------------
// Data model for server groups
// ---------------------------------------------------------------------------

class _ServerGroup {
  final String domain;
  final XmppServerConfig? config;
  final String? viaServerName;
  final String connectionServerId;
  final String? confService;
  final List<XmppRoom> rooms;

  _ServerGroup({
    required this.domain,
    this.config,
    this.viaServerName,
    required this.connectionServerId,
    this.confService,
    required this.rooms,
  });

  bool get isConfigured => config != null;
  bool get isFederated => config == null;
}
