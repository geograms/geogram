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
    final xmpp = XmppService();
    final config = xmpp.servers.where((s) => s.id == widget.serverId).firstOrNull;
    final confService = config?.derivedConferenceService ?? '';

    // Trigger room discovery
    xmpp.discoverRooms(widget.serverId);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XmppRoomBrowserPage(
          serverId: widget.serverId,
          confService: confService,
        ),
      ),
    );
  }
}

/// Full-page room browser with search and discovery results.
class XmppRoomBrowserPage extends StatefulWidget {
  final String serverId;
  final String confService;

  const XmppRoomBrowserPage({super.key, required this.serverId, required this.confService});

  @override
  State<XmppRoomBrowserPage> createState() => _XmppRoomBrowserPageState();
}

class _XmppRoomBrowserPageState extends State<XmppRoomBrowserPage> {
  final _searchCtl = TextEditingController();
  StreamSubscription<XmppEvent>? _eventSub;
  List<Map<String, dynamic>> _rooms = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rooms = XmppService().getRoomList(widget.serverId);
    if (_rooms.isNotEmpty) _loading = false;

    _eventSub = XmppService().events.listen((event) {
      if (event.type == XmppEventType.roomListReceived &&
          event.serverId == widget.serverId) {
        if (!mounted) return;
        setState(() {
          _rooms = XmppService().getRoomList(widget.serverId);
          _loading = false;
          if (_rooms.isEmpty && event.data is Map && event.data['error'] != null) {
            _error = event.data['error'].toString();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _searchCtl.text.toLowerCase();
    final filtered = query.isEmpty
        ? _rooms
        : _rooms.where((r) {
            final name = (r['name'] as String? ?? '').toLowerCase();
            final jid = (r['jid'] as String? ?? '').toLowerCase();
            return name.contains(query) || jid.contains(query);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Browse Rooms (${widget.confService})'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: 'Search or enter room JID...',
                prefixIcon: const Icon(Icons.search, size: 20),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _searchCtl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtl.clear();
                          setState(() {});
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) {
                final jid = value.trim();
                if (jid.isNotEmpty) _joinRoom(jid);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  _loading
                      ? 'Discovering rooms...'
                      : _error != null
                          ? 'Error: $_error'
                          : '${filtered.length} rooms${query.isNotEmpty ? ' matching' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (!_loading)
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = null;
                      });
                      XmppService().discoverRooms(widget.serverId);
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh'),
                  ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            )
          else
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        query.isNotEmpty ? 'No rooms match "$query"' : 'No rooms found',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final room = filtered[index];
                        final jid = room['jid'] as String? ?? '';
                        final name = room['name'] as String? ?? jid.split('@').first;
                        final alreadyJoined = XmppService()
                            .getRooms(widget.serverId)
                            .any((r) => r.jid == jid);

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: alreadyJoined
                                ? Colors.green.withValues(alpha: 0.15)
                                : const Color(0xFFFF6600).withValues(alpha: 0.15),
                            child: Icon(
                              alreadyJoined ? Icons.check : Icons.forum,
                              size: 20,
                              color: alreadyJoined ? Colors.green : const Color(0xFFFF6600),
                            ),
                          ),
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            jid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: alreadyJoined
                              ? const Text('Joined', style: TextStyle(color: Colors.green))
                              : null,
                          onTap: alreadyJoined ? null : () => _joinRoom(jid),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }

  void _joinRoom(String roomJid) {
    if (roomJid.isEmpty) return;
    if (!roomJid.contains('@') && widget.confService.isNotEmpty) {
      roomJid = '$roomJid@${widget.confService}';
    }
    XmppService().joinRoom(widget.serverId, roomJid);
    Navigator.pop(context);
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
