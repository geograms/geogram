/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Room list widget for an XMPP server.
 * Shows joined rooms with last message preview, timestamp, and unread count.
 * FAB to browse and join rooms — always visible when connected.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../xmpp_service.dart';
import '../models/xmpp_room.dart';
import '../pages/xmpp_chat_page.dart';

class XmppRoomList extends StatefulWidget {
  final String serverId;

  const XmppRoomList({super.key, required this.serverId});

  @override
  State<XmppRoomList> createState() => _XmppRoomListState();
}

class _XmppRoomListState extends State<XmppRoomList> {
  StreamSubscription<XmppEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    XmppService().addUiObserver();
    _eventSub = XmppService().events.listen((_) {
      if (mounted) setState(() {});
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
    final rooms = xmpp.getRooms(widget.serverId);
    final connected = xmpp.isConnected(widget.serverId);
    final theme = Theme.of(context);

    return Stack(
      children: [
        if (rooms.isEmpty)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.forum,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  connected ? 'No rooms joined' : 'Not connected',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  connected
                      ? 'Tap + to join a room'
                      : 'Connect to the server first',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          )
        else
          ListView.builder(
            itemCount: _sorted(rooms).length,
            itemBuilder: (context, index) {
              final room = _sorted(rooms)[index];
              return _RoomTile(
                room: room,
                onTap: () => _openRoom(context, room),
              );
            },
          ),
        // FAB always visible when connected
        if (connected)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              onPressed: () => _showJoinDialog(context),
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }

  List<XmppRoom> _sorted(List<XmppRoom> rooms) {
    final sorted = List<XmppRoom>.from(rooms)
      ..sort((a, b) {
        // Rooms with unread messages first
        if (a.unreadCount > 0 && b.unreadCount == 0) return -1;
        if (a.unreadCount == 0 && b.unreadCount > 0) return 1;
        if (a.unreadCount > 0 && b.unreadCount > 0) {
          final cmp = b.unreadCount.compareTo(a.unreadCount);
          if (cmp != 0) return cmp;
        }
        // Then by last message timestamp
        final aTime = a.lastMessage?.timestamp;
        final bTime = b.lastMessage?.timestamp;
        if (aTime == null && bTime == null) return a.jid.compareTo(b.jid);
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
    return sorted;
  }

  void _openRoom(BuildContext context, XmppRoom room) {
    XmppService().markRoomRead(widget.serverId, room.jid);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XmppChatPage(
          serverId: widget.serverId,
          roomJid: room.jid,
        ),
      ),
    );
  }

  void _showJoinDialog(BuildContext context) {
    final controller = TextEditingController();
    final xmpp = XmppService();
    final config = xmpp.servers.where((s) => s.id == widget.serverId).firstOrNull;
    final confService = config?.derivedConferenceService ?? '';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Room'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Room JID',
                hintText: 'room@$confService',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              autofocus: true,
              onSubmitted: (value) {
                _joinRoom(ctx, controller.text.trim(), confService);
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the full room JID (e.g., room@$confService)',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _joinRoom(ctx, controller.text.trim(), confService);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  void _joinRoom(BuildContext ctx, String roomJid, String confService) {
    if (roomJid.isEmpty) return;
    // Auto-append conference service if no @ present
    if (!roomJid.contains('@') && confService.isNotEmpty) {
      roomJid = '$roomJid@$confService';
    }
    XmppService().joinRoom(widget.serverId, roomJid);
    Navigator.pop(ctx);
  }
}

class _RoomTile extends StatelessWidget {
  final XmppRoom room;
  final VoidCallback onTap;

  const _RoomTile({required this.room, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastMsg = room.lastMessage;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFFF6600).withValues(alpha: 0.15),
        child: const Icon(
          Icons.forum,
          size: 20,
          color: Color(0xFFFF6600),
        ),
      ),
      title: Text(
        room.name.isNotEmpty ? room.name : room.jid.split('@').first,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: lastMsg != null
          ? Text(
              lastMsg.isSystemMessage
                  ? lastMsg.text
                  : '${lastMsg.sender}: ${lastMsg.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Text(
              room.subject.isNotEmpty
                  ? room.subject
                  : '${room.occupants.length} occupants',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (lastMsg != null)
            Text(
              _formatTime(lastMsg.timestamp),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (room.unreadCount > 0)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 3),
              Text(
                '${room.occupants.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _formatTime(DateTime utcDate) {
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
