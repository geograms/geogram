/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC chat page — reversed ListView with message bubbles and compose bar.
 * System messages (join/part/quit) shown as centered gray text.
 * AppBar: topic, user count chip (tappable → user list), overflow menu.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import '../../shared/teleport_chat_utils.dart';
import '../irc_service.dart';
import '../widgets/irc_message_bubble.dart';

class IrcChatPage extends StatefulWidget {
  final String serverId;
  final String channel;

  const IrcChatPage({
    super.key,
    required this.serverId,
    required this.channel,
  });

  @override
  State<IrcChatPage> createState() => _IrcChatPageState();
}

class _IrcChatPageState extends State<IrcChatPage> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  StreamSubscription<IrcEvent>? _eventSub;
  bool _loadedCache = false;
  Timer? _typingTimer;
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    IrcService().addUiObserver();
    // Mark as read on open
    IrcService().markChannelRead(widget.serverId, widget.channel);
    _eventSub = IrcService().events.listen((event) {
      if (!mounted) return;

      // Show snackbar on error
      if (event.type == IrcEventType.error &&
          event.serverId == widget.serverId) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${event.data}'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }

      // Show snackbar on nick change
      if (event.type == IrcEventType.messageReceived) {
        // nick changes come as UI tick after nick_changed sets _uiDirty
      }

      // If we got kicked/parted from this channel, pop back
      if (event.type == IrcEventType.channelLeft &&
          event.serverId == widget.serverId &&
          event.data == widget.channel) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Left ${widget.channel}')),
        );
        Navigator.of(context).pop();
        return;
      }

      // If server disconnected, pop back
      if (event.type == IrcEventType.disconnected &&
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
    await IrcService().loadCachedMessages(widget.serverId, widget.channel);
    _loadedCache = true;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    IrcService().removeUiObserver();
    // Mark as read on leave — catches messages that arrived while viewing
    IrcService().markChannelRead(widget.serverId, widget.channel);
    _eventSub?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    _typingTimer?.cancel();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final irc = IrcService();

    // Check for slash commands
    if (text.startsWith('/') && !text.startsWith('/me ')) {
      if (irc.handleSlashCommand(widget.serverId, widget.channel, text)) {
        _textController.clear();
        _focusNode.requestFocus();
        return;
      }
    }

    if (!irc.isConnected(widget.serverId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to server')),
      );
      return;
    }

    final sent = irc.sendMessage(widget.serverId, widget.channel, text);
    if (sent != null) {
      _textController.clear();
      _focusNode.requestFocus();
      _setTyping(false);
    }
  }

  void _leaveChannel() {
    IrcService().partChannel(widget.serverId, widget.channel);
    // Pop will happen via channelLeft event listener above
  }

  void _showUserList() {
    final irc = IrcService();
    final channelInfo = irc.getChannels(widget.serverId)
        .where((ch) => ch.name == widget.channel)
        .firstOrNull;
    if (channelInfo == null) return;

    final users = List<String>.from(channelInfo.users)..sort(
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
                    'Users (${users.length})',
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
                itemCount: users.length,
                itemBuilder: (_, i) {
                  final user = users[i];
                  final isMe = user == irc.currentNick(widget.serverId);
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: teleportSenderColor(user).withValues(alpha: 0.2),
                      child: Text(
                        user[0].toUpperCase(),
                        style: TextStyle(
                          color: teleportSenderColor(user),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    title: Text(
                      user,
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
                      // Pre-fill compose bar with /msg username
                      _textController.text = '/msg $user ';
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
    final irc = IrcService();
    final messages = irc.getMessages(widget.serverId, widget.channel);
    final channelInfo = irc.getChannels(widget.serverId)
        .where((ch) => ch.name == widget.channel)
        .firstOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.channel, style: const TextStyle(fontSize: 16)),
            if (channelInfo != null && channelInfo.topic.isNotEmpty)
              Text(
                channelInfo.topic,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          // Tappable user count chip
          if (channelInfo != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                avatar: const Icon(Icons.people, size: 16),
                label: Text('${channelInfo.users.length}'),
                visualDensity: VisualDensity.compact,
                onPressed: _showUserList,
              ),
            ),
          // Overflow menu
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'leave':
                  _leaveChannel();
                case 'users':
                  _showUserList();
                case 'help':
                  _showSlashCommandHelp();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'users',
                child: ListTile(
                  leading: Icon(Icons.people),
                  title: Text('User List'),
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
                  title: Text('Leave Channel', style: TextStyle(color: Colors.red)),
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
          // Message list (reversed)
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
                      // Reversed list: newest first
                      final msg = messages[messages.length - 1 - index];
                      final prevMsg = index < messages.length - 1
                          ? messages[messages.length - 2 - index]
                          : null;

                      final widgets = <Widget>[];

                      // Date separator
                      if (prevMsg == null || !_sameDay(msg.timestamp, prevMsg.timestamp)) {
                        widgets.add(TeleportDateSeparator(date: msg.timestamp));
                      }

                      // System message or bubble
                      if (msg.isSystemMessage) {
                        widgets.add(IrcSystemMessage(message: msg));
                      } else {
                        final showSender = !msg.isOutgoing &&
                            (prevMsg == null ||
                                prevMsg.sender != msg.sender ||
                                prevMsg.isSystemMessage);
                        widgets.add(
                          IrcMessageBubble(
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
          _buildTypingIndicator(theme),
          // Compose bar
          _buildComposeBar(theme),
        ],
      ),
    );
  }


  void _handleTypingChanged(String value) {
    if (!IrcService().isConnected(widget.serverId)) return;
    if (value.trim().isEmpty) {
      _setTyping(false);
      return;
    }
    _setTyping(true);
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      _setTyping(false);
    });
  }

  void _setTyping(bool isTyping) {
    if (_isTyping == isTyping) return;
    _isTyping = isTyping;
    IrcService().sendTyping(widget.serverId, widget.channel, isTyping);
  }

  Widget _buildTypingIndicator(ThemeData theme) {
    final users = IrcService().getTypingUsers(widget.serverId, widget.channel);
    if (users.isEmpty) return const SizedBox.shrink();

    String label;
    if (users.length == 1) {
      label = '${users.first} is typing...';
    } else if (users.length == 2) {
      label = '${users[0]} and ${users[1]} are typing...';
    } else {
      label = '${users[0]} and ${users.length - 1} others are typing...';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
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
            _CmdHelp('/join #channel', 'Join a channel'),
            _CmdHelp('/part [#channel]', 'Leave current or specified channel'),
            _CmdHelp('/nick newname', 'Change your nickname'),
            _CmdHelp('/msg user text', 'Send a private message'),
            _CmdHelp('/topic text', 'Set channel topic'),
            _CmdHelp('/me action', 'Send an action message'),
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
                  hintText: 'Message ${widget.channel}',
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
                onChanged: _handleTypingChanged,
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
            width: 140,
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
