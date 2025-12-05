/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/device_source.dart';
import '../models/chat_channel.dart';
import '../models/relay_chat_room.dart';
import '../services/i18n_service.dart';

/// Unified sidebar for browsing chat rooms across multiple devices
/// Shows local device channels and remote device (relay/direct) rooms
class DeviceChatSidebar extends StatefulWidget {
  /// Local device channels
  final List<ChatChannel> localChannels;

  /// List of connected device sources (relays, direct connections)
  final List<DeviceSourceWithRooms> remoteSources;

  /// Currently selected local channel ID
  final String? selectedLocalChannelId;

  /// Currently selected remote room (device ID + room ID)
  final SelectedRemoteRoom? selectedRemoteRoom;

  /// Callback when local channel is selected
  final Function(ChatChannel) onLocalChannelSelect;

  /// Callback when remote room is selected
  final Function(DeviceSource, RelayChatRoom) onRemoteRoomSelect;

  /// Callback to create new local channel (null hides the button)
  final VoidCallback? onNewLocalChannel;

  /// Callback to refresh a remote device's rooms
  final Function(DeviceSource)? onRefreshDevice;

  /// Local device callsign
  final String localCallsign;

  /// Unread counts map (room ID -> count)
  final Map<String, int> unreadCounts;

  const DeviceChatSidebar({
    Key? key,
    required this.localChannels,
    required this.remoteSources,
    this.selectedLocalChannelId,
    this.selectedRemoteRoom,
    required this.onLocalChannelSelect,
    required this.onRemoteRoomSelect,
    this.onNewLocalChannel,
    this.onRefreshDevice,
    required this.localCallsign,
    this.unreadCounts = const {},
  }) : super(key: key);

  @override
  State<DeviceChatSidebar> createState() => _DeviceChatSidebarState();
}

class _DeviceChatSidebarState extends State<DeviceChatSidebar> {
  final I18nService _i18n = I18nService();

  /// Track which device sections are expanded
  final Map<String, bool> _expandedDevices = {'local': true};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
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
                // Remote device sections (relay rooms first)
                for (final source in widget.remoteSources)
                  _buildDeviceSection(
                    theme,
                    source.device,
                    null,
                    source.rooms,
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
          Icon(
            Icons.chat,
            color: theme.colorScheme.primary,
            size: 24,
          ),
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
    List<RelayChatRoom>? remoteRooms,
  ) {
    // Default to expanded if:
    // - It's a remote device (relay), OR
    // - There are no remote sources (local only mode)
    final defaultExpanded = !device.isLocal || widget.remoteSources.isEmpty;
    final isExpanded = _expandedDevices[device.id] ?? defaultExpanded;
    final hasItems = (localChannels?.isNotEmpty ?? false) ||
        (remoteRooms?.isNotEmpty ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Device header (expandable)
        _buildDeviceHeader(theme, device, isExpanded, hasItems),
        // Expanded content
        if (isExpanded) ...[
          if (localChannels != null)
            ...localChannels.map((channel) => _buildLocalChannelTile(theme, channel)),
          if (remoteRooms != null)
            ...remoteRooms.map((room) => _buildRemoteRoomTile(theme, device, room)),
        ],
      ],
    );
  }

  Widget _buildDeviceHeader(
    ThemeData theme,
    DeviceSource device,
    bool isExpanded,
    bool hasItems,
  ) {
    final icon = _getDeviceIcon(device.type);
    final statusColor = device.isOnline ? Colors.green : Colors.grey;

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
              // Status dot
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
              Icon(
                icon,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              // Device name and callsign
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (device.callsign != null)
                      Text(
                        device.callsign!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              // Status text (only shown when offline)
              if (device.statusText.isNotEmpty)
                Text(
                  device.statusText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: device.isOnline
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                    fontSize: 10,
                  ),
                ),
              // Refresh button for remote devices
              if (!device.isLocal && widget.onRefreshDevice != null)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: () => widget.onRefreshDevice?.call(device),
                  tooltip: _i18n.t('refresh'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onLocalChannelSelect(channel),
        child: Padding(
          padding: const EdgeInsets.only(left: 44, right: 12, top: 8, bottom: 8),
          child: Row(
            children: [
              // Channel icon
              _buildChannelIcon(theme, channel),
              const SizedBox(width: 10),
              // Channel name
              Expanded(
                child: Text(
                  channel.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected
                        ? theme.colorScheme.onPrimaryContainer
                        : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteRoomTile(
    ThemeData theme,
    DeviceSource device,
    RelayChatRoom room,
  ) {
    final isSelected = widget.selectedRemoteRoom?.deviceId == device.id &&
        widget.selectedRemoteRoom?.roomId == room.id;
    final unreadCount = widget.unreadCounts[room.id] ?? 0;

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onRemoteRoomSelect(device, room),
        child: Padding(
          padding: const EdgeInsets.only(left: 44, right: 12, top: 8, bottom: 8),
          child: Row(
            children: [
              // Room icon
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.forum,
                  size: 16,
                  color: theme.colorScheme.tertiary,
                ),
              ),
              const SizedBox(width: 10),
              // Room name
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected
                            ? theme.colorScheme.onPrimaryContainer
                            : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChannelIcon(ThemeData theme, ChatChannel channel) {
    IconData icon;
    Color color;

    if (channel.isMain) {
      icon = Icons.forum;
      color = theme.colorScheme.primary;
    } else if (channel.isDirect) {
      icon = Icons.person;
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
      child: Icon(
        icon,
        size: 16,
        color: color,
      ),
    );
  }

  IconData _getDeviceIcon(DeviceSourceType type) {
    switch (type) {
      case DeviceSourceType.local:
        return Icons.smartphone;
      case DeviceSourceType.relay:
        return Icons.cell_tower;
      case DeviceSourceType.direct:
        return Icons.wifi_tethering;
    }
  }
}

/// Combines a device source with its chat rooms
class DeviceSourceWithRooms {
  final DeviceSource device;
  final List<RelayChatRoom> rooms;
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

  SelectedRemoteRoom({
    required this.deviceId,
    required this.roomId,
  });
}
