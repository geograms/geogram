/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR user profile page with follow/unfollow and recent posts.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/i18n_service.dart';
import '../../../util/nostr_crypto.dart';
import '../../shared/teleport_chat_utils.dart';
import '../models/nostr_feed_item.dart';
import '../nostr_client_service.dart';
import '../widgets/nostr_event_tile.dart';

class NostrUserProfilePage extends StatefulWidget {
  final String pubkey;

  const NostrUserProfilePage({super.key, required this.pubkey});

  @override
  State<NostrUserProfilePage> createState() => _NostrUserProfilePageState();
}

class _NostrUserProfilePageState extends State<NostrUserProfilePage> {
  StreamSubscription<NostrClientEvent>? _eventSub;
  bool _busy = false;
  bool _isFollowed = false;
  Map<String, String?>? _profile;
  List<NostrFeedItem> _posts = [];

  @override
  void initState() {
    super.initState();
    final service = NostrClientService();
    _isFollowed = service.follows.contains(widget.pubkey);
    _profile = service.getProfile(widget.pubkey);
    _posts = service.getPostsByPubkey(widget.pubkey);
    service.requestUserPosts(widget.pubkey);
    _eventSub = service.events.listen((event) {
      if (!mounted) return;
      setState(() {
        _isFollowed = service.follows.contains(widget.pubkey);
        _profile = service.getProfile(widget.pubkey);
        _posts = service.getPostsByPubkey(widget.pubkey);
      });
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  String get _npub => NostrCrypto.encodeNpub(widget.pubkey);

  String _displayName() {
    final name = _profile?['name'];
    if (name != null && name.isNotEmpty) return name;
    if (_npub.length > 16) return '${_npub.substring(0, 12)}...';
    return _npub;
  }

  Future<void> _toggleFollow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final service = NostrClientService();
    final next = !_isFollowed;
    setState(() => _isFollowed = next);

    final ok = next
        ? await service.followUser(widget.pubkey)
        : await service.unfollowUser(widget.pubkey);
    if (!ok && mounted) {
      setState(() => _isFollowed = !next);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18nService().t('nostr_follow_failed'))),
      );
    }
    if (mounted) setState(() => _busy = false);
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

  void _copyNpub() {
    Clipboard.setData(ClipboardData(text: _npub));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(I18nService().t('nostr_npub_copied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final about = _profile?['about'] ?? '';
    final nip05 = _profile?['nip05'] ?? '';
    final picture = _profile?['picture'] ?? '';
    final avatarColor = teleportSenderColor(widget.pubkey);
    final displayName = _displayName();

    return Scaffold(
      appBar: AppBar(
        title: Text(_displayName()),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: I18nService().t('nostr_copy_npub_tooltip'),
            onPressed: _copyNpub,
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: _posts.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        backgroundColor: avatarColor.withValues(alpha: 0.2),
                        child: picture.isEmpty
                            ? Text(
                                displayName.substring(0, 1).toUpperCase(),
                                style: TextStyle(
                                  color: avatarColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 22,
                                ),
                              )
                            : ClipOval(
                                child: Image.network(
                                  picture,
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) {
                                    return Center(
                                      child: Text(
                                        displayName.substring(0, 1).toUpperCase(),
                                        style: TextStyle(
                                          color: avatarColor,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 22,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              style: theme.textTheme.titleLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _npub,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (nip05.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    Icons.verified,
                                    size: 16,
                                    color: Colors.blue.shade300,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      nip05,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy ? null : _toggleFollow,
                        child: Text(_isFollowed ? I18nService().t('nostr_unfollow_btn') : I18nService().t('nostr_follow_btn')),
                      ),
                    ],
                  ),
                  if (about.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      about,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Divider(color: theme.dividerColor.withValues(alpha: 0.4)),
                  const SizedBox(height: 4),
                  Text(
                    I18nService().t('nostr_recent_posts_label'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          }

          final item = _posts[index - 1];
          return NostrEventTile(
            item: item,
            onLike: () => _likePost(item),
          );
        },
      ),
    );
  }
}
