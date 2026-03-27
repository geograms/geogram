/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/device_source.dart';
import '../models/chat_channel.dart';
import '../models/station_chat_room.dart';
import '../services/i18n_service.dart';

/// Unified sidebar for browsing chat rooms across multiple devices
/// Shows local device channels and remote device (station/direct) rooms
class DeviceChatSidebar extends StatefulWidget {
  /// Local device channels
  final List<ChatChannel> localChannels;

  /// Nickname map (uppercase callsign -> display name) for DM channels
  final Map<String, String> nicknameMap;

  /// Profile picture map (uppercase callsign -> ImageProvider) for DM channels
  final Map<String, ImageProvider> profilePicMap;

  /// List of connected device sources (stations, direct connections)
  final List<DeviceSourceWithRooms> remoteSources;

  /// Currently selected local channel ID
  final String? selectedLocalChannelId;

  /// Currently selected remote room (device ID + room ID)
  final SelectedRemoteRoom? selectedRemoteRoom;

  /// Callback when local channel is selected
  final Function(ChatChannel) onLocalChannelSelect;

  /// Callback when remote room is selected
  final Function(DeviceSource, StationChatRoom) onRemoteRoomSelect;

  /// Callback to create new local channel (null hides the button)
  final VoidCallback? onNewLocalChannel;

  /// Callback to refresh a remote device's rooms
  final Function(DeviceSource)? onRefreshDevice;

  /// Local device callsign
  final String localCallsign;

  /// Unread counts map (room ID -> count)
  final Map<String, int> unreadCounts;

  /// Set of muted room IDs
  final Set<String> mutedRooms;

  /// Callback to toggle mute for a room
  final Function(String roomId)? onToggleMute;

  /// Callback to delete a local channel
  final Function(ChatChannel channel)? onDeleteLocalChannel;

  /// Whether the user is a moderator on the station (enables room management)
  final bool isModerator;

  /// Callback to create a new station room (null hides the button)
  final Future<void> Function(String id, String name, {String? description})?
  onCreateRoom;

  /// Callback to delete a station room
  final Future<void> Function(StationChatRoom room)? onDeleteRoom;

  /// Callback to rename a station room
  final Future<void> Function(StationChatRoom room, String newName)?
  onRenameRoom;

  const DeviceChatSidebar({
    Key? key,
    required this.localChannels,
    this.nicknameMap = const {},
    this.profilePicMap = const {},
    required this.remoteSources,
    this.selectedLocalChannelId,
    this.selectedRemoteRoom,
    required this.onLocalChannelSelect,
    required this.onRemoteRoomSelect,
    this.onNewLocalChannel,
    this.onRefreshDevice,
    required this.localCallsign,
    this.unreadCounts = const {},
    this.mutedRooms = const {},
    this.onToggleMute,
    this.onDeleteLocalChannel,
    this.isModerator = false,
    this.onCreateRoom,
    this.onDeleteRoom,
    this.onRenameRoom,
  }) : super(key: key);

  @override
  State<DeviceChatSidebar> createState() => _DeviceChatSidebarState();
}

class _DeviceChatSidebarState extends State<DeviceChatSidebar> {
  final I18nService _i18n = I18nService();

  /// Track which device sections are expanded
  final Map<String, bool> _expandedDevices = {'local': true};

  /// Resolve DM display name: "nickname (CALLSIGN)" or just callsign
  String _dmDisplayName(ChatChannel channel) {
    final callsign = channel.name.toUpperCase();
    final nickname = widget.nicknameMap[callsign];
    if (nickname != null && nickname.isNotEmpty) {
      return '$nickname ($callsign)';
    }
    return channel.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        children: [
          // Header
          _buildHeader(theme),
          const Divider(height: 1),
          // Scrollable device list
          Expanded(
            child: ListView(
              children: [
                // Remote device sections (station rooms first)
                for (final source in widget.remoteSources)
                  _buildDeviceSection(
                    theme,
                    source.device,
                    null,
                    source.rooms,
                    source.isLoading,
                  ),
                // Local device section (only show if there are local channels)
                if (widget.localChannels.isNotEmpty)
                  _buildDeviceSection(
                    theme,
                    DeviceSource.local(
                      callsign: widget.localCallsign,
                      nickname: 'This Device',
                    ),
                    widget.localChannels,
                    null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.chat, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 12),
          Text(
            _i18n.t('chat_rooms'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSection(
    ThemeData theme,
    DeviceSource device,
    List<ChatChannel>? localChannels,
    List<StationChatRoom>? remoteRooms, [
    bool isLoading = false,
  ]) {
    // Default to expanded if:
    // - It's a remote device (station), OR
    // - There are no remote sources (local only mode)
    final defaultExpanded = !device.isLocal || widget.remoteSources.isEmpty;
    final isExpanded = _expandedDevices[device.id] ?? defaultExpanded;
    final hasItems =
        (localChannels?.isNotEmpty ?? false) ||
        (remoteRooms?.isNotEmpty ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Device header (expandable)
        _buildDeviceHeader(theme, device, isExpanded, hasItems, isLoading),
        // Expanded content
        if (isExpanded) ...[
          if (localChannels != null)
            ...localChannels.map(
              (channel) => _buildLocalChannelTile(theme, channel),
            ),
          if (remoteRooms != null)
            ...remoteRooms.map(
              (room) => _buildRemoteRoomTile(theme, device, room),
            ),
        ],
      ],
    );
  }

  /// Check if a string looks like a URL
  bool _isUrlLike(String value) {
    return value.startsWith('wss://') ||
        value.startsWith('ws://') ||
        value.startsWith('https://') ||
        value.startsWith('http://');
  }

  /// Strip protocol prefix from URL (wss://, ws://, https://, http://)
  String _stripUrlProtocol(String url) {
    return url
        .replaceFirst('wss://', '')
        .replaceFirst('ws://', '')
        .replaceFirst('https://', '')
        .replaceFirst('http://', '');
  }

  /// Format device title: show "Nickname (CALLSIGN)" when nickname available,
  /// URL domain when no nickname, callsign as last resort
  String _formatDeviceTitle(DeviceSource device) {
    final name = device.name;
    final callsign = device.callsign;
    final url = device.url;

    // Check if name is a proper nickname (not empty, not a URL, not same as callsign)
    final hasNickname =
        name.isNotEmpty && !_isUrlLike(name) && name != callsign;

    if (hasNickname) {
      // Show "Nickname (domain)" when we have a proper nickname and URL
      if (url != null && url.isNotEmpty) {
        return '$name (${_stripUrlProtocol(url)})';
      }
      return callsign != null ? '$name ($callsign)' : name;
    }

    // No nickname - prefer URL domain over callsign
    if (url != null && url.isNotEmpty) {
      return _stripUrlProtocol(url);
    }

    // Last resort: callsign
    return callsign ?? name;
  }

  Widget _buildDeviceHeader(
    ThemeData theme,
    DeviceSource device,
    bool isExpanded,
    bool hasItems, [
    bool isLoading = false,
  ]) {
    final icon = _getDeviceIcon(device.type);
    final isConnecting = isLoading && !device.isOnline;
    final statusColor = device.isOnline
        ? Colors.green
        : isConnecting
        ? Colors.grey
        : Colors.grey;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: hasItems
            ? () {
                setState(() {
                  _expandedDevices[device.id] = !isExpanded;
                });
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Expand/collapse indicator
              Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: hasItems
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              ),
              const SizedBox(width: 4),
              // Status indicator: spinner when connecting, dot otherwise
              if (isConnecting)
                SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.grey,
                  ),
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
              const SizedBox(width: 8),
              // Device icon
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              // Device name and callsign
              Expanded(
                child: Text(
                  _formatDeviceTitle(device),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Status text: "Connecting..." when loading, "Not reachable" when offline
              if (isConnecting)
                Text(
                  'Connecting...',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                    fontSize: 10,
                  ),
                )
              else if (device.statusText.isNotEmpty)
                Text(
                  device.statusText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: device.isOnline
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                    fontSize: 10,
                  ),
                ),
              // Add room button for station devices when moderator
              if (widget.isModerator && widget.onCreateRoom != null)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(Icons.add, color: theme.colorScheme.primary),
                    tooltip: _i18n.t('create_room'),
                    onPressed: () => _showCreateRoomDialog(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLocalChannelTile(ThemeData theme, ChatChannel channel) {
    final isSelected = widget.selectedLocalChannelId == channel.id;
    final unreadCount = channel.unreadCount;
    final isMuted = widget.mutedRooms.contains(channel.id);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onLocalChannelSelect(channel),
        child: Padding(
          padding: const EdgeInsets.only(left: 44, right: 8, top: 8, bottom: 8),
          child: Row(
            children: [
              // Channel icon
              _buildChannelIcon(theme, channel),
              const SizedBox(width: 10),
              // Channel name + muted indicator
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        channel.isDirect
                            ? _dmDisplayName(channel)
                            : channel.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSelected
                              ? theme.colorScheme.onPrimaryContainer
                              : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isMuted)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.notifications_off,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Favorite indicator
              if (channel.isFavorite)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.star,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                ),
              // Unread badge
              if (unreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : unreadCount.toString(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
              // Channel menu (mute, delete)
              if (widget.onToggleMute != null)
                _buildChannelMenuButton(theme, channel, isMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteRoomTile(
    ThemeData theme,
    DeviceSource device,
    StationChatRoom room,
  ) {
    final isSelected =
        widget.selectedRemoteRoom?.deviceId == device.id &&
        widget.selectedRemoteRoom?.roomId == room.id;
    final unreadCount = widget.unreadCounts[room.id] ?? 0;
    final isMuted = widget.mutedRooms.contains(room.id);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onRemoteRoomSelect(device, room),
        child: Padding(
          padding: const EdgeInsets.only(left: 44, right: 8, top: 8, bottom: 8),
          child: Row(
            children: [
              // Room icon
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.forum,
                  size: 16,
                  color: theme.colorScheme.tertiary,
                ),
              ),
              const SizedBox(width: 10),
              // Room name + muted indicator
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            room.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? theme.colorScheme.onPrimaryContainer
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMuted)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.notifications_off,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                      ],
                    ),
                    if (room.description.isNotEmpty)
                      Text(
                        room.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              // Unread badge
              if (unreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : unreadCount.toString(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiary,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
              // Room context menu (mute + moderator actions for remote rooms)
              if (widget.onToggleMute != null)
                _buildRemoteRoomMenuButton(theme, device, room, isMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteRoomMenuButton(
    ThemeData theme,
    DeviceSource device,
    StationChatRoom room,
    bool isMuted,
  ) {
    final canManage = widget.isModerator && room.id != 'general';

    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(
          Icons.more_vert,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        onSelected: (value) {
          switch (value) {
            case 'toggle_mute':
              widget.onToggleMute?.call(room.id);
              break;
            case 'rename':
              _showRenameRoomDialog(context, room);
              break;
            case 'delete':
              _showDeleteRoomDialog(context, room);
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            value: 'toggle_mute',
            height: 40,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isMuted
                      ? Icons.notifications_active
                      : Icons.notifications_off,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  isMuted
                      ? _i18n.t('unmute_notifications')
                      : _i18n.t('mute_notifications'),
                ),
              ],
            ),
          ),
          if (canManage) ...[
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'rename',
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit, size: 18),
                  const SizedBox(width: 8),
                  Text(_i18n.t('rename_room')),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'delete',
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Text(
                    _i18n.t('delete_room'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChannelMenuButton(
    ThemeData theme,
    ChatChannel channel,
    bool isMuted,
  ) {
    final canDelete =
        !channel.isMain &&
        !(channel.config?.isDistributed ?? false) &&
        widget.onDeleteLocalChannel != null;

    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(
          Icons.more_vert,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        onSelected: (value) {
          if (value == 'toggle_mute') {
            widget.onToggleMute?.call(channel.id);
          } else if (value == 'delete') {
            _confirmDeleteChannel(context, channel);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            value: 'toggle_mute',
            height: 40,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isMuted
                      ? Icons.notifications_active
                      : Icons.notifications_off,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  isMuted
                      ? _i18n.t('unmute_notifications')
                      : _i18n.t('mute_notifications'),
                ),
              ],
            ),
          ),
          if (canDelete) ...[
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'delete',
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  const SizedBox(width: 8),
                  Text(_i18n.t('delete'), style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _confirmDeleteChannel(BuildContext context, ChatChannel channel) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_i18n.t('delete')} "${channel.name}"?'),
        content: Text(_i18n.t('delete_channel_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDeleteLocalChannel?.call(channel);
            },
            child: Text(_i18n.t('delete'), style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelIcon(ThemeData theme, ChatChannel channel) {
    // For DM channels, show profile picture if available
    if (channel.isDirect) {
      final profilePic = widget.profilePicMap[channel.name.toUpperCase()];
      return CircleAvatar(
        radius: 14,
        backgroundColor: theme.colorScheme.secondaryContainer,
        backgroundImage: profilePic,
        child: profilePic == null
            ? Icon(
                Icons.person,
                size: 16,
                color: theme.colorScheme.onSecondaryContainer,
              )
            : null,
      );
    }

    final customIcon = channel.icon?.trim();
    if (customIcon != null && customIcon.isNotEmpty) {
      return Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(customIcon, style: const TextStyle(fontSize: 16)),
      );
    }

    IconData icon;
    Color color;

    if (channel.isMain) {
      icon = Icons.forum;
      color = theme.colorScheme.primary;
    } else if (channel.config?.isDistributed ?? false) {
      icon = Icons.hub;
      color = theme.colorScheme.secondary;
    } else {
      icon = Icons.group;
      color = theme.colorScheme.tertiary;
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }

  IconData _getDeviceIcon(DeviceSourceType type) {
    switch (type) {
      case DeviceSourceType.local:
        return Icons.smartphone;
      case DeviceSourceType.station:
        return Icons.cell_tower;
      case DeviceSourceType.direct:
        return Icons.wifi_tethering;
      case DeviceSourceType.ble:
        return Icons.bluetooth;
      case DeviceSourceType.usb:
        return Icons.usb;
    }
  }

  void _showCreateRoomDialog(BuildContext context) {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_i18n.t('create_room')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(labelText: _i18n.t('room_name')),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descController,
              decoration: InputDecoration(labelText: _i18n.t('description')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              final id = name.toLowerCase().replaceAll(
                RegExp(r'[^a-z0-9]+'),
                '-',
              );
              final desc = descController.text.trim();
              Navigator.pop(ctx);
              widget.onCreateRoom?.call(
                id,
                name,
                description: desc.isEmpty ? null : desc,
              );
            },
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );
  }

  void _showRenameRoomDialog(BuildContext context, StationChatRoom room) {
    final controller = TextEditingController(text: room.name);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_i18n.t('rename_room')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: _i18n.t('room_name')),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isEmpty || newName == room.name) return;
              Navigator.pop(ctx);
              widget.onRenameRoom?.call(room, newName);
            },
            child: Text(_i18n.t('rename')),
          ),
        ],
      ),
    );
  }

  void _showDeleteRoomDialog(BuildContext context, StationChatRoom room) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_i18n.t('delete_room')),
        content: Text('${_i18n.t('delete_room_confirm')} "${room.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDeleteRoom?.call(room);
            },
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );
  }
}

/// Combines a device source with its chat rooms
class DeviceSourceWithRooms {
  final DeviceSource device;
  final List<StationChatRoom> rooms;
  final bool isLoading;

  DeviceSourceWithRooms({
    required this.device,
    required this.rooms,
    this.isLoading = false,
  });
}

/// Identifies a selected remote room
class SelectedRemoteRoom {
  final String deviceId;
  final String roomId;

  SelectedRemoteRoom({required this.deviceId, required this.roomId});
}
