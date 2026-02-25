/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP chat page — reversed ListView with message bubbles and compose bar.
 * System messages (join/leave) shown as centered gray text.
 * AppBar: room name, subject, occupant count chip.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import '../../shared/teleport_chat_utils.dart';
import '../xmpp_service.dart';
import '../widgets/xmpp_message_bubble.dart';

class XmppChatPage extends StatefulWidget {
  final String serverId;
  final String roomJid;

  const XmppChatPage({
    super.key,
    required this.serverId,
    required this.roomJid,
  });

  @override
  State<XmppChatPage> createState() => _XmppChatPageState();
}

class _XmppChatPageState extends State<XmppChatPage> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  StreamSubscription<XmppEvent>? _eventSub;
  bool _loadedCache = false;

  @override
  void initState() {
    super.initState();
    XmppService().addUiObserver();
    // Mark as read on open
    XmppService().markRoomRead(widget.serverId, widget.roomJid);
    _eventSub = XmppService().events.listen((event) {
      if (!mounted) return;

      if (event.type == XmppEventType.error &&
          event.serverId == widget.serverId) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${event.data}'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }

      // If we left this room, pop back
      if (event.type == XmppEventType.roomLeft &&
          event.serverId == widget.serverId &&
          event.data == widget.roomJid) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Left ${widget.roomJid.split('@').first}')),
        );
        Navigator.of(context).pop();
        return;
      }

      // If server disconnected, pop back
      if (event.type == XmppEventType.disconnected &&
          event.serverId == widget.serverId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Disconnected from server')),
        );
        Navigator.of(context).pop();
        return;
      }

      setState(() {});
    });
    _loadCache();
  }

  Future<void> _loadCache() async {
    await XmppService().loadCachedMessages(widget.serverId, widget.roomJid);
    _loadedCache = true;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    XmppService().removeUiObserver();
    XmppService().markRoomRead(widget.serverId, widget.roomJid);
    _eventSub?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final xmpp = XmppService();

    // Check for slash commands
    if (text.startsWith('/') && !text.startsWith('/me ')) {
      if (xmpp.handleSlashCommand(widget.serverId, widget.roomJid, text)) {
        _textController.clear();
        _focusNode.requestFocus();
        return;
      }
    }

    if (!xmpp.isConnected(widget.serverId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to server')),
      );
      return;
    }

    final sent = xmpp.sendMessage(widget.serverId, widget.roomJid, text);
    if (sent != null) {
      _textController.clear();
      _focusNode.requestFocus();
    }
  }

  void _leaveRoom() {
    XmppService().leaveRoom(widget.serverId, widget.roomJid);
  }

  void _showOccupantList() {
    final xmpp = XmppService();
    final roomInfo = xmpp.getRooms(widget.serverId)
        .where((r) => r.jid == widget.roomJid)
        .firstOrNull;
    if (roomInfo == null) return;

    final occupants = List<String>.from(roomInfo.occupants)..sort(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    'Occupants (${occupants.length})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: occupants.length,
                itemBuilder: (_, i) {
                  final occ = occupants[i];
                  final isMe = occ == xmpp.currentNick(widget.serverId);
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: teleportSenderColor(occ).withValues(alpha: 0.2),
                      child: Text(
                        occ[0].toUpperCase(),
                        style: TextStyle(
                          color: teleportSenderColor(occ),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    title: Text(
                      occ,
                      style: TextStyle(
                        fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: isMe
                        ? Text('you', style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ))
                        : null,
                    onTap: isMe ? null : () {
                      Navigator.pop(ctx);
                      _textController.text = '/msg $occ ';
                      _focusNode.requestFocus();
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final xmpp = XmppService();
    final messages = xmpp.getMessages(widget.serverId, widget.roomJid);
    final roomInfo = xmpp.getRooms(widget.serverId)
        .where((r) => r.jid == widget.roomJid)
        .firstOrNull;
    final theme = Theme.of(context);
    final roomName = roomInfo?.name ?? widget.roomJid.split('@').first;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(roomName, style: const TextStyle(fontSize: 16)),
            if (roomInfo != null && roomInfo.subject.isNotEmpty)
              Text(
                roomInfo.subject,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (roomInfo != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                avatar: const Icon(Icons.people, size: 16),
                label: Text('${roomInfo.occupants.length}'),
                visualDensity: VisualDensity.compact,
                onPressed: _showOccupantList,
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'leave':
                  _leaveRoom();
                case 'occupants':
                  _showOccupantList();
                case 'help':
                  _showSlashCommandHelp();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'occupants',
                child: ListTile(
                  leading: Icon(Icons.people),
                  title: Text('Occupant List'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'help',
                child: ListTile(
                  leading: Icon(Icons.help_outline),
                  title: Text('Slash Commands'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'leave',
                child: ListTile(
                  leading: Icon(Icons.exit_to_app, color: Colors.red),
                  title: Text('Leave Room', style: TextStyle(color: Colors.red)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      _loadedCache ? 'No messages yet' : 'Loading...',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[messages.length - 1 - index];
                      final prevMsg = index < messages.length - 1
                          ? messages[messages.length - 2 - index]
                          : null;

                      final widgets = <Widget>[];

                      if (prevMsg == null || !_sameDay(msg.timestamp, prevMsg.timestamp)) {
                        widgets.add(TeleportDateSeparator(date: msg.timestamp));
                      }

                      if (msg.isSystemMessage) {
                        widgets.add(XmppSystemMessage(message: msg));
                      } else {
                        final showSender = !msg.isOutgoing &&
                            (prevMsg == null ||
                                prevMsg.sender != msg.sender ||
                                prevMsg.isSystemMessage);
                        widgets.add(
                          XmppMessageBubble(
                            message: msg,
                            showSender: showSender,
                          ),
                        );
                      }

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: widgets,
                      );
                    },
                  ),
          ),
          _buildComposeBar(theme),
        ],
      ),
    );
  }

  void _showSlashCommandHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Slash Commands'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CmdHelp('/join room@server', 'Join a room'),
            _CmdHelp('/part [room]', 'Leave current or specified room'),
            _CmdHelp('/subject text', 'Set room subject'),
            _CmdHelp('/msg user text', 'Send a private message'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildComposeBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: 'Message ${widget.roomJid.split('@').first}',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                maxLines: null,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sendMessage,
              icon: const Icon(Icons.send, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }
}

class _CmdHelp extends StatelessWidget {
  final String command;
  final String description;

  const _CmdHelp(this.command, this.description);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              command,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
