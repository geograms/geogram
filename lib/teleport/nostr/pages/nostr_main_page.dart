/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR main page — social feed view with Firehose/Only Follows filter,
 * compose bar for publishing kind:1 notes.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/profile_service.dart';
import '../../../util/nostr_crypto.dart';
import '../nostr_client_service.dart';
import '../models/nostr_feed_item.dart';
import '../widgets/nostr_event_tile.dart';
import 'nostr_settings_page.dart';
import 'nostr_user_profile_page.dart';

class NostrMainPage extends StatefulWidget {
  final String appPath;

  const NostrMainPage({super.key, required this.appPath});

  @override
  State<NostrMainPage> createState() => _NostrMainPageState();
}

class _NostrMainPageState extends State<NostrMainPage> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  StreamSubscription<NostrClientEvent>? _eventSub;
  Timer? _searchTimer;

  String? _ownPubkey;
  bool _isSearching = false;
  NostrFeedItem? _replyTarget;

  @override
  void initState() {
    super.initState();
    _resolveOwnPubkey();
    _searchController.addListener(() {
      _scheduleSearch();
      if (mounted) setState(() {});
    });
    _eventSub = NostrClientService().events.listen((event) {
      if (!mounted) return;
      setState(() {});

      if (event.type == NostrClientEventType.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('NOSTR: ${event.data}'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });
  }

  void _resolveOwnPubkey() {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isNotEmpty) {
        _ownPubkey = NostrCrypto.decodeNpub(profile.npub);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchTimer?.cancel();
    super.dispose();
  }

  void _publish() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final service = NostrClientService();
    if (!service.isAnyConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to any relay')),
      );
      return;
    }

    final target = _replyTarget;
    final ok = target == null
        ? await service.publish(text)
        : await service.publishReply(text, target.event);
    if (ok) {
      _textController.clear();
      _focusNode.requestFocus();
      if (target != null) {
        setState(() => _replyTarget = null);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to publish note')),
        );
      }
    }
  }

  Future<void> _likePost(NostrFeedItem item) async {
    final eventId = item.id;
    if (eventId == null) return;
    final ok = await NostrClientService().likeEvent(eventId, item.pubkey);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to like post')),
      );
    }
  }

  void _openUserProfile(String pubkey) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NostrUserProfilePage(pubkey: pubkey),
      ),
    );
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _searchFocusNode.unfocus();
        NostrClientService().requestSearch('');
      } else {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _scheduleSearch() {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 400), () {
      NostrClientService().requestSearch(_searchController.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = NostrClientService();
    final items = service.searchFeed(_searchController.text);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                decoration: const InputDecoration(
                  hintText: 'Search NOSTR',
                  border: InputBorder.none,
                ),
                style: theme.textTheme.titleMedium,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('NOSTR'),
                  if (items.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${items.length}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            tooltip: _isSearching ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
          ),
          // Filter dropdown
          DropdownButton<NostrFeedFilter>(
            value: service.feedFilter,
            underline: const SizedBox.shrink(),
            icon: const Icon(Icons.filter_list, size: 20),
            items: const [
              DropdownMenuItem(
                value: NostrFeedFilter.firehose,
                child: Text('Firehose'),
              ),
              DropdownMenuItem(
                value: NostrFeedFilter.onlyFollows,
                child: Text('Only Follows'),
              ),
            ],
            onChanged: (filter) {
              if (filter != null) {
                setState(() {
                  service.feedFilter = filter;
                });
              }
            },
          ),
          const SizedBox(width: 4),
          // Pause/play toggle
          IconButton(
            icon: Icon(service.isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: service.isPaused ? 'Resume feed' : 'Pause feed',
            onPressed: () {
              service.togglePause();
              setState(() {});
            },
          ),
          // Settings
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Relay Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NostrSettingsPage(appPath: widget.appPath),
                ),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
          ),
        ],
      ),
      body: !service.isAnyConnected && items.isEmpty
          ? _buildEmptyState(theme)
          : Column(
              children: [
                Expanded(
                  child: _buildFeed(items, theme),
                ),
                _buildComposeBar(theme),
              ],
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hub,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            'Connect to relays to see the NOSTR feed',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap the settings gear to configure relays',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NostrSettingsPage(appPath: widget.appPath),
                ),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
            icon: const Icon(Icons.settings),
            label: const Text('Relay Settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildFeed(List<NostrFeedItem> items, ThemeData theme) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_searchController.text.trim().isEmpty) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Waiting for events...',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              Icon(
                Icons.search_off,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                'No results',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // Newest-first feed (social media style)
    final reversedItems = items.reversed.toList();

    return ListView.builder(
      padding: const EdgeInsets.only(top: 4),
      itemCount: reversedItems.length,
      itemBuilder: (context, index) {
        final item = reversedItems[index];
        final isOwn = _ownPubkey != null && item.pubkey == _ownPubkey;

        return NostrEventTile(
          item: item,
          isOwnPost: isOwn,
          onLike: () => _likePost(item),
          onReply: () {
            setState(() => _replyTarget = item);
            _focusNode.requestFocus();
          },
          onToggleFollow: () => _toggleFollow(item),
          onTapAuthor: () => _openUserProfile(item.pubkey),
        );
      },
    );
  }

  Future<void> _toggleFollow(NostrFeedItem item) async {
    final service = NostrClientService();
    final ok = item.isFollowed
        ? await service.unfollowUser(item.pubkey)
        : await service.followUser(item.pubkey);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to update follow status')),
      );
    }
  }

  Widget _buildComposeBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTarget != null)
              Container(
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Replying to ${_replyTarget!.displayName}',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => setState(() => _replyTarget = null),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: _replyTarget == null
                          ? 'Write a note...'
                          : 'Write a reply...',
                      border: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      isDense: true,
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _publish(),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.send,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: _publish,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
