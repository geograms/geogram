/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../models/atproto_profile.dart';
import '../widgets/atproto_post_tile.dart';

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
                  onLike: () => AtprotoClientService().likePost(item),
                  onRepost: () => AtprotoClientService().repost(item),
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
}
