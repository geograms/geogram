/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../models/atproto_profile.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_thread_page.dart';

class AtprotoProfilePage extends StatefulWidget {
  final String actor;

  const AtprotoProfilePage({super.key, required this.actor});

  @override
  State<AtprotoProfilePage> createState() => _AtprotoProfilePageState();
}

class _AtprotoProfilePageState extends State<AtprotoProfilePage> {
  AtprotoProfile? _profile;
  List<AtprotoFeedItem> _posts = const [];
  bool _loading = true;
  bool _followBusy = false;
  bool _isFollowing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = AtprotoClientService();
      final profile = await service.fetchProfile(widget.actor);
      final posts = await service.fetchAuthorFeed(widget.actor, limit: 50);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _posts = posts;
        _isFollowing = profile?.isFollowedByMe ?? false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          profile?.displayName.isNotEmpty == true
              ? profile!.displayName
              : '@${profile?.handle.isNotEmpty == true ? profile!.handle : widget.actor}',
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            _buildHeader(context, profile),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Failed to load profile: $_error'),
                  ),
                ),
              ),
            if (!_loading && _error == null && _posts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No publications yet')),
              ),
            if (_posts.isNotEmpty)
              ..._posts.map(
                (item) => AtprotoPostTile(
                  item: item,
                  compact: true,
                  onLike: () => _like(item),
                  onRepost: () => _repost(item),
                  onOpenThread: () => _openThread(item),
                  onTapAuthor: () => _openAuthorProfile(item),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AtprotoProfile? profile) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 120,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.25),
                  theme.colorScheme.tertiary.withValues(alpha: 0.2),
                ],
              ),
              image:
                  profile?.bannerUrl != null && profile!.bannerUrl!.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(profile.bannerUrl!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.translate(
                  offset: const Offset(0, -24),
                  child: CircleAvatar(
                    radius: 34,
                    backgroundColor: theme.colorScheme.surface,
                    child: CircleAvatar(
                      radius: 30,
                      backgroundImage: profile?.avatarUrl != null
                          ? NetworkImage(profile!.avatarUrl!)
                          : null,
                      child: profile?.avatarUrl == null
                          ? Text(
                              _profileInitial(profile),
                              style: const TextStyle(fontSize: 18),
                            )
                          : null,
                    ),
                  ),
                ),
                Text(
                  profile?.displayName.isNotEmpty == true
                      ? profile!.displayName
                      : (profile?.handle.isNotEmpty == true
                            ? profile!.handle
                            : widget.actor),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '@${profile?.handle.isNotEmpty == true ? profile!.handle : widget.actor}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                _buildFollowButton(profile),
                if (profile?.description.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(profile!.description, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 14,
                  children: [
                    _stat(
                      theme,
                      '${profile?.postsCount ?? _posts.length}',
                      'Posts',
                    ),
                    _stat(
                      theme,
                      '${profile?.followersCount ?? 0}',
                      'Followers',
                    ),
                    _stat(theme, '${profile?.followsCount ?? 0}', 'Following'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(ThemeData theme, String value, String label) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: ' $label',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _profileInitial(AtprotoProfile? profile) {
    final seed =
        (profile?.displayName.isNotEmpty == true
                ? profile!.displayName
                : profile?.handle ?? widget.actor)
            .trim();
    if (seed.isEmpty) return '?';
    return seed.substring(0, 1).toUpperCase();
  }

  Widget _buildFollowButton(AtprotoProfile? profile) {
    final service = AtprotoClientService();
    final targetDid = profile?.did ?? '';
    final isSelf = targetDid.isNotEmpty && targetDid == service.session?.did;
    if (isSelf) return const SizedBox.shrink();

    return SizedBox(
      height: 34,
      child: FilledButton.icon(
        onPressed: _followBusy
            ? null
            : () => _follow(
                profile?.did.isNotEmpty == true ? profile!.did : widget.actor,
              ),
        icon: Icon(
          _isFollowing ? Icons.check : Icons.person_add_alt_1,
          size: 16,
        ),
        label: Text(_isFollowing ? 'Following' : 'Follow'),
      ),
    );
  }

  void _like(AtprotoFeedItem item) {
    AtprotoClientService().likePost(item).then((ok) {
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not like this post')),
        );
      }
    });
  }

  void _repost(AtprotoFeedItem item) {
    AtprotoClientService().repost(item).then((ok) {
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not repost this post')),
        );
      }
    });
  }

  void _openThread(AtprotoFeedItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AtprotoThreadPage(rootPost: item)),
    );
  }

  void _openAuthorProfile(AtprotoFeedItem item) {
    final actor = item.authorDid.startsWith('did:')
        ? item.authorDid
        : item.authorHandle;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AtprotoProfilePage(actor: actor)));
  }

  Future<void> _follow(String actor) async {
    setState(() => _followBusy = true);
    final ok = await AtprotoClientService().followActor(actor);
    if (!mounted) return;
    if (ok) {
      setState(() => _isFollowing = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Followed profile')));
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not follow profile')));
    }
    setState(() => _followBusy = false);
  }
}
