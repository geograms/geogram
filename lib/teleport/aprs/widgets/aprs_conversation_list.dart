/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Conversation list widget for APRS Messages tab.
 * Shows grouped conversations (direct 1:1 and tag rooms) with FAB for
 * composing new messages.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/devices_service.dart';
import '../../../services/user_location_service.dart';
import '../../shared/teleport_chat_utils.dart';
import '../aprs_service.dart';
import '../models/aprs_conversation.dart';
import '../pages/aprs_conversation_page.dart';
import '../pages/aprs_main_page.dart' show distanceKm, formatDistanceKm;

class AprsConversationList extends StatefulWidget {
  final UserLocation? myLocation;

  const AprsConversationList({super.key, this.myLocation});

  @override
  State<AprsConversationList> createState() => _AprsConversationListState();
}

class _AprsConversationListState extends State<AprsConversationList> {
  StreamSubscription<AprsEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _eventSub = AprsService().events.listen((event) {
      if (event.type == AprsEventType.messageReceived && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aprs = AprsService();
    final conversations = aprs.getConversations();

    if (conversations.isEmpty && aprs.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'No conversations yet',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Messages addressed to your callsign\nand subscribed #tags will appear here',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          itemCount: conversations.length,
          itemBuilder: (context, index) {
            final conv = conversations[index];
            return Dismissible(
              key: ValueKey(conv.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: Theme.of(context).colorScheme.error,
                child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onError),
              ),
              confirmDismiss: (_) => _confirmDelete(context, conv.displayName),
              onDismissed: (_) => AprsService().clearConversation(conv.id),
              child: _ConversationTile(
                conversation: conv,
                myLocation: widget.myLocation,
                onTap: () => _openConversation(context, conv),
                onLongPress: () => _showConversationActions(context, conv),
              ),
            );
          },
        ),
        // FAB for new message
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: () => _showNewMessageSheet(context),
            child: const Icon(Icons.edit),
          ),
        ),
        // Clear-all button
        if (conversations.isNotEmpty)
          Positioned(
            right: 16,
            bottom: 80,
            child: FloatingActionButton.small(
              heroTag: 'clear_all_messages',
              onPressed: () => _confirmClearAll(context),
              tooltip: 'Clear all messages',
              child: const Icon(Icons.delete_sweep),
            ),
          ),
      ],
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversation'),
        content: Text('Delete all messages with $name?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    ) ?? false;
  }

  void _confirmClearAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all messages'),
        content: const Text('Delete all APRS message conversations? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear all')),
        ],
      ),
    );
    if (confirmed == true) {
      await AprsService().clearAllMessages();
    }
  }

  void _showConversationActions(BuildContext context, AprsConversation conv) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text('Delete messages with ${conv.displayName}'),
              onTap: () async {
                Navigator.pop(ctx);
                final confirmed = await _confirmDelete(context, conv.displayName);
                if (confirmed) {
                  await AprsService().clearConversation(conv.id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openConversation(BuildContext context, AprsConversation conv) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AprsConversationPage(
          conversationId: conv.id,
          conversationType: conv.type,
          partnerPosition: conv.partnerPosition,
          myLocation: widget.myLocation,
        ),
      ),
    );
  }

  void _showNewMessageSheet(BuildContext context) async {
    final callsign = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _AprsCallsignPicker(),
    );
    if (callsign != null && context.mounted) {
      _openConversation(
        context,
        AprsConversation(
          id: callsign,
          type: AprsConversationType.direct,
        ),
      );
    }
  }
}

class _ConversationTile extends StatelessWidget {
  final AprsConversation conversation;
  final UserLocation? myLocation;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ConversationTile({
    required this.conversation,
    this.myLocation,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDirect = conversation.type == AprsConversationType.direct;

    // Distance indicator for direct conversations
    String? distStr;
    if (isDirect && conversation.partnerPosition != null) {
      final dist = distanceKm(
        conversation.partnerPosition!.$1,
        conversation.partnerPosition!.$2,
        myLocation,
      );
      if (dist != null) distStr = formatDistanceKm(dist);
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isDirect
            ? teleportSenderColor(conversation.id).withValues(alpha: 0.2)
            : theme.colorScheme.primaryContainer,
        child: isDirect
            ? Text(
                conversation.id.isNotEmpty
                    ? conversation.id[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: teleportSenderColor(conversation.id),
                  fontWeight: FontWeight.w600,
                ),
              )
            : Icon(
                Icons.tag,
                color: theme.colorScheme.onPrimaryContainer,
              ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conversation.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _formatTime(conversation.lastMessageTime),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              conversation.lastMessagePreview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (distStr != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                distStr,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(local.year, local.month, local.day);
    final diff = today.difference(msgDay).inDays;

    if (diff == 0) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return 'Yesterday';
    if (diff < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}';
  }
}

class _AprsCallsignPicker extends StatefulWidget {
  const _AprsCallsignPicker();

  @override
  State<_AprsCallsignPicker> createState() => _AprsCallsignPickerState();
}

class _AprsCallsignPickerState extends State<_AprsCallsignPicker> {
  final _callsignController = TextEditingController();
  final _searchController = TextEditingController();
  final _devicesService = DevicesService();
  final Set<String> _expandedFolders = {};
  bool _isSearching = false;
  List<RemoteDevice> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _autoExpandFolders();
  }

  void _autoExpandFolders() {
    final folders = _devicesService.getFolders();
    final foldersWithDevices = folders.where(
      (f) => _devicesService.getDevicesInFolder(f.id).isNotEmpty,
    ).toList();
    if (foldersWithDevices.length == 1) {
      _expandedFolders.add(foldersWithDevices.first.id);
    }
  }

  void _onSearchChanged(String query) {
    if (query.isEmpty) {
      setState(() {
        _isSearching = false;
        _searchResults = [];
      });
      return;
    }
    final lower = query.toLowerCase();
    final all = _devicesService.getAllDevices();
    setState(() {
      _isSearching = true;
      _searchResults = all.where((d) {
        return d.callsign.toLowerCase().contains(lower) ||
            d.displayName.toLowerCase().contains(lower);
      }).toList();
    });
  }

  void _submit(String callsign) {
    final trimmed = callsign.trim().toUpperCase();
    if (trimmed.isNotEmpty) {
      Navigator.of(context).pop(trimmed);
    }
  }

  @override
  void dispose() {
    _callsignController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'New Message',
                style: theme.textTheme.titleLarge,
              ),
            ),
          ),
          // Callsign input row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _callsignController,
                    decoration: const InputDecoration(
                      hintText: 'Enter callsign (e.g., N0CALL-9)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.go,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: _submit,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _callsignController.text.trim().isEmpty
                      ? null
                      : () => _submit(_callsignController.text),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
          // Divider with label
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or choose a contact',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
          ),
          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search contacts',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          // Device list
          Expanded(
            child: _isSearching
                ? _buildSearchResults(scrollController)
                : _buildFolderList(scrollController),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(ScrollController controller) {
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          'No contacts found',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      itemCount: _searchResults.length,
      itemBuilder: (context, index) => _deviceTile(_searchResults[index]),
    );
  }

  Widget _buildFolderList(ScrollController controller) {
    final folders = _devicesService.getFolders();
    return ListView.builder(
      controller: controller,
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        final devices = _devicesService.getDevicesInFolder(folder.id);
        final isExpanded = _expandedFolders.contains(folder.id);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isExpanded ? Icons.folder_open : Icons.folder,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text('${folder.name} (${devices.length})'),
              trailing: Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
              ),
              dense: true,
              onTap: () => setState(() {
                if (isExpanded) {
                  _expandedFolders.remove(folder.id);
                } else {
                  _expandedFolders.add(folder.id);
                }
              }),
            ),
            if (isExpanded)
              for (final device in devices) _deviceTile(device),
          ],
        );
      },
    );
  }

  Widget _deviceTile(RemoteDevice device) {
    final color = teleportSenderColor(device.callsign);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.2),
        child: Text(
          device.callsign.isNotEmpty ? device.callsign[0] : '?',
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ),
      title: Text(
        device.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Row(
        children: [
          Text(device.callsign),
          if (device.isOnline) ...[
            const SizedBox(width: 6),
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'Online',
              style: TextStyle(
                color: Colors.green.shade300,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      dense: true,
      onTap: () => Navigator.of(context).pop(device.callsign.toUpperCase()),
    );
  }
}
