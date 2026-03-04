/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Channel list widget for an IRC server.
 * Shows joined channels with last message preview, timestamp, and unread count.
 * FAB to browse and join channels — always visible (even when no channels joined).
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../irc_service.dart';
import '../models/irc_channel.dart';
import '../pages/irc_chat_page.dart';

class IrcChannelList extends StatefulWidget {
  final String serverId;

  const IrcChannelList({super.key, required this.serverId});

  @override
  State<IrcChannelList> createState() => _IrcChannelListState();
}

class _IrcChannelListState extends State<IrcChannelList> {
  StreamSubscription<IrcEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    IrcService().addUiObserver();
    _eventSub = IrcService().events.listen((_) {
      if (mounted) setState(() {});
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
    final channels = irc.getChannels(widget.serverId);
    final connected = irc.isConnected(widget.serverId);
    final theme = Theme.of(context);

    return Stack(
      children: [
        if (channels.isEmpty)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.tag,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  connected ? 'No channels joined' : 'Not connected',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  connected
                      ? 'Tap + to browse and join channels'
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
            itemCount: _sorted(channels).length,
            itemBuilder: (context, index) {
              final ch = _sorted(channels)[index];
              return _ChannelTile(
                channel: ch,
                onTap: () => _openChannel(context, ch),
              );
            },
          ),
        // FAB always visible when connected
        if (connected)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              onPressed: () => _openChannelBrowser(context),
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }

  List<IrcChannel> _sorted(List<IrcChannel> channels) {
    final sorted = List<IrcChannel>.from(channels)
      ..sort((a, b) {
        // Channels with unread messages first
        if (a.unreadCount > 0 && b.unreadCount == 0) return -1;
        if (a.unreadCount == 0 && b.unreadCount > 0) return 1;
        // Among channels with unreads, sort by count descending
        if (a.unreadCount > 0 && b.unreadCount > 0) {
          final cmp = b.unreadCount.compareTo(a.unreadCount);
          if (cmp != 0) return cmp;
        }
        // Then by last message timestamp
        final aTime = a.lastMessage?.timestamp;
        final bTime = b.lastMessage?.timestamp;
        if (aTime == null && bTime == null) return a.name.compareTo(b.name);
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
    return sorted;
  }

  void _openChannel(BuildContext context, IrcChannel channel) {
    IrcService().markChannelRead(widget.serverId, channel.name);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IrcChatPage(
          serverId: widget.serverId,
          channel: channel.name,
        ),
      ),
    );
  }

  void _openChannelBrowser(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ChannelBrowserPage(serverId: widget.serverId),
      ),
    );
  }
}

/// Full-page channel browser — requests LIST from the server,
/// shows results in a searchable list sorted by user count.
class _ChannelBrowserPage extends StatefulWidget {
  final String serverId;

  const _ChannelBrowserPage({required this.serverId});

  @override
  State<_ChannelBrowserPage> createState() => _ChannelBrowserPageState();
}

class _ChannelBrowserPageState extends State<_ChannelBrowserPage> {
  StreamSubscription<IrcEvent>? _eventSub;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _manualController = TextEditingController();
  bool _loading = false;
  bool _loaded = false;
  List<Map<String, dynamic>> _allChannels = [];
  String _searchQuery = '';
  /// Channels currently being joined (waiting for server confirm).
  final Set<String> _pendingJoins = {};

  @override
  void initState() {
    super.initState();
    _eventSub = IrcService().events.listen((event) {
      if (event.type == IrcEventType.channelListReceived &&
          event.serverId == widget.serverId) {
        setState(() {
          _allChannels = IrcService().getChannelList(widget.serverId);
          _loading = false;
          _loaded = true;
        });
      }
      if (event.type == IrcEventType.channelJoined &&
          event.serverId == widget.serverId) {
        final channelName = event.data as String?;
        if (mounted && channelName != null) {
          _pendingJoins.remove(channelName.toLowerCase());
          setState(() {});
        }
      }
    });
    _requestList();
  }

  void _requestList() {
    setState(() {
      _loading = true;
      _loaded = false;
    });
    IrcService().requestChannelList(widget.serverId);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _searchController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final list = _searchQuery.isEmpty
        ? List<Map<String, dynamic>>.from(_allChannels)
        : _allChannels.where((ch) {
            final q = _searchQuery.toLowerCase();
            final name = (ch['channel'] as String? ?? '').toLowerCase();
            final topic = (ch['topic'] as String? ?? '').toLowerCase();
            return name.contains(q) || topic.contains(q);
          }).toList();
    list.sort((a, b) {
      final aCount = a['userCount'] as int? ?? 0;
      final bCount = b['userCount'] as int? ?? 0;
      return bCount.compareTo(aCount);
    });
    return list;
  }

  Set<String> get _joinedNames {
    return IrcService()
        .getChannels(widget.serverId)
        .map((ch) => ch.name.toLowerCase())
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;
    final joined = _joinedNames;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse Channels'),
        actions: [
          if (_loaded)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _requestList,
            ),
        ],
      ),
      body: Column(
        children: [
          // Manual join bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualController,
                    decoration: InputDecoration(
                      hintText: '#channel',
                      labelText: 'Join by name',
                      prefixText: _manualController.text.isEmpty ? '# ' : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (value) => _joinManual(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _joinManual,
                  child: const Text('Join'),
                ),
              ],
            ),
          ),
          // Search bar for server channel list
          if (_loaded && _allChannels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search ${_allChannels.length} channels...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _searchQuery = value.trim()),
              ),
            ),
          const SizedBox(height: 4),
          // Channel list
          Expanded(
            child: _loading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Fetching channel list from server...'),
                      ],
                    ),
                  )
                : !_loaded || _allChannels.isEmpty
                    ? Center(
                        child: Text(
                          _loaded
                              ? 'No channels found on this server'
                              : 'Tap refresh to load channels',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : filtered.isEmpty
                        ? Center(
                            child: Text(
                              'No channels match "$_searchQuery"',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final ch = filtered[index];
                              final name = ch['channel'] as String? ?? '';
                              final userCount = ch['userCount'] as int? ?? 0;
                              final topic = ch['topic'] as String? ?? '';
                              final isJoined = joined.contains(name.toLowerCase());
                              final isPending = _pendingJoins.contains(name.toLowerCase());

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isJoined
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : const Color(0xFF4CAF50).withValues(alpha: 0.08),
                                  child: isJoined
                                      ? const Icon(Icons.check, color: Colors.green, size: 20)
                                      : Text(
                                          '#',
                                          style: TextStyle(
                                            color: const Color(0xFF4CAF50),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 18,
                                          ),
                                        ),
                                ),
                                title: Text(
                                  name,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: isJoined ? Colors.green : null,
                                  ),
                                ),
                                subtitle: isJoined
                                    ? Text(
                                        'Joined',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: Colors.green.withValues(alpha: 0.7),
                                        ),
                                      )
                                    : topic.isNotEmpty
                                        ? Text(
                                            topic,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: theme.colorScheme.onSurfaceVariant,
                                            ),
                                          )
                                        : null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '$userCount',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.people,
                                      size: 14,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    if (isPending)
                                      const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    else if (isJoined)
                                      const Icon(
                                        Icons.arrow_forward_ios,
                                        size: 14,
                                        color: Colors.green,
                                      )
                                    else
                                      const Icon(
                                        Icons.add_circle_outline,
                                        size: 18,
                                      ),
                                  ],
                                ),
                                onTap: isPending || isJoined
                                    ? null
                                    : () {
                                        setState(() => _pendingJoins.add(name.toLowerCase()));
                                        IrcService().joinChannel(widget.serverId, name);
                                      },
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  void _joinManual() {
    var ch = _manualController.text.trim();
    if (ch.isEmpty) return;
    if (!ch.startsWith('#')) ch = '#$ch';
    setState(() => _pendingJoins.add(ch.toLowerCase()));
    IrcService().joinChannel(widget.serverId, ch);
    _manualController.clear();
    // Channel will appear as joined once channelJoined event fires
  }
}

class _ChannelTile extends StatelessWidget {
  final IrcChannel channel;
  final VoidCallback onTap;

  const _ChannelTile({required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastMsg = channel.lastMessage;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF4CAF50).withValues(alpha: 0.15),
        child: Text(
          '#',
          style: TextStyle(
            color: const Color(0xFF4CAF50),
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      title: Text(
        channel.name,
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
              channel.topic.isNotEmpty ? channel.topic : '${channel.users.length} users',
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
              if (channel.unreadCount > 0)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${channel.unreadCount}',
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
                '${channel.users.length}',
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
