/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../atproto_link_parser.dart';
import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../models/atproto_profile.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_actor_list_page.dart';
import 'atproto_thread_page.dart';

class AtprotoProfilePage extends StatefulWidget {
  final String actor;

  const AtprotoProfilePage({super.key, required this.actor});

  @override
  State<AtprotoProfilePage> createState() => _AtprotoProfilePageState();
}

class _AtprotoProfilePageState extends State<AtprotoProfilePage> {
  static final RegExp _urlRegex = RegExp(
    r'(https?://[^\s]+|www\.[^\s]+|bsky\.app/[^\s]+)',
    caseSensitive: false,
  );
  final List<TapGestureRecognizer> _descriptionRecognizers = [];
  AtprotoProfile? _profile;
  List<AtprotoFeedItem> _posts = const [];
  List<AtprotoFeedItem> _mediaPosts = const [];
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
    final service = AtprotoClientService();
    AtprotoProfile? profile;
    List<AtprotoFeedItem> posts = const [];
    List<AtprotoFeedItem> mediaPosts = const [];
    String? loadError;
    try {
      profile = await service.fetchProfile(widget.actor);
    } catch (e) {
      loadError = '$e';
    }

    try {
      posts = await service.fetchAuthorFeed(widget.actor, limit: 50);
    } catch (e) {
      loadError ??= '$e';
    }
    try {
      mediaPosts = await service.fetchAuthorMediaFeed(widget.actor, limit: 50);
    } catch (e) {
      loadError ??= '$e';
    }

    if (profile == null && service.isLocalActor(widget.actor)) {
      profile = service.localProfileSnapshot();
    }

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _posts = posts;
      _mediaPosts = mediaPosts;
      _isFollowing =
          profile?.isFollowedByMe == true ||
          service.isFollowingActor(
            did: profile?.did,
            handle: profile?.handle,
            actor: widget.actor,
          );
      // Avoid showing fatal error when we still have fallback local profile/posts.
      _error = (_profile == null && _posts.isEmpty) ? loadError : null;
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final recognizer in _descriptionRecognizers) {
      recognizer.dispose();
    }
    super.dispose();
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
      body: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            _buildHeader(context, profile),
            const TabBar(
              tabs: [
                Tab(text: 'Posts'),
                Tab(text: 'Media'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [_buildPostList(_posts), _buildPostList(_mediaPosts)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostList(List<AtprotoFeedItem> posts) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
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
                  child: SelectableText('Failed to load profile: $_error'),
                ),
              ),
            ),
          if (!_loading && _error == null && posts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No publications yet')),
            ),
          ...posts.map(
            (item) => AtprotoPostTile(
              item: item,
              compact: true,
              onLike: () => _like(item),
              onRepost: () => _repost(item),
              onOpenThread: () => _openThread(item),
              onTapAuthor: () => _openAuthorProfile(item),
              onOpenProfileActor: _openProfileByActor,
              onOpenPostUri: _openThreadByUri,
            ),
          ),
        ],
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
                  child: MouseRegion(
                    cursor: profile?.avatarUrl?.isNotEmpty == true
                        ? SystemMouseCursors.click
                        : MouseCursor.defer,
                    child: GestureDetector(
                      onTap: profile?.avatarUrl?.isNotEmpty == true
                          ? () => _openImagePreview(profile!.avatarUrl!)
                          : null,
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
                  _buildDescriptionText(theme, profile!.description),
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
                      onTap: () =>
                          _openActorList(AtprotoActorListType.followers),
                    ),
                    _stat(
                      theme,
                      '${profile?.followsCount ?? 0}',
                      'Following',
                      onTap: () =>
                          _openActorList(AtprotoActorListType.following),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(
    ThemeData theme,
    String value,
    String label, {
    VoidCallback? onTap,
  }) {
    final content = RichText(
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
    if (onTap == null) return content;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: content),
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
      if (!mounted) return;
      if (!ok) {
        _showActionError('Could not like this post');
        return;
      }
      _patchPostState(
        item.uri,
        (current) => current.copyWith(
          isLikedByMe: true,
          likeCount: current.likeCount + 1,
        ),
      );
    });
  }

  void _repost(AtprotoFeedItem item) {
    AtprotoClientService().repost(item).then((ok) {
      if (!mounted) return;
      if (!ok) {
        _showActionError('Could not repost this post');
        return;
      }
      _patchPostState(
        item.uri,
        (current) => current.copyWith(
          isRepostedByMe: true,
          repostCount: current.repostCount + 1,
        ),
      );
    });
  }

  void _openThread(AtprotoFeedItem item) {
    final target = item.rootUri?.isNotEmpty == true
        ? item.rootUri!.trim()
        : item.uri;
    _openThreadByUri(target);
  }

  void _openAuthorProfile(AtprotoFeedItem item) {
    final actor = item.authorDid.startsWith('did:')
        ? item.authorDid
        : item.authorHandle;
    _openProfileByActor(actor);
  }

  void _openProfileByActor(String actor) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AtprotoProfilePage(actor: actor)));
  }

  void _openThreadByUri(String postUri) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AtprotoThreadPage(rootPostUri: postUri),
      ),
    );
  }

  Widget _buildDescriptionText(ThemeData theme, String text) {
    for (final recognizer in _descriptionRecognizers) {
      recognizer.dispose();
    }
    _descriptionRecognizers.clear();

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: text.substring(cursor, match.start),
            style: theme.textTheme.bodyMedium,
          ),
        );
      }
      final raw = match.group(0)!;
      final normalized = raw.startsWith('http') ? raw : 'https://$raw';
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _openDescriptionLink(normalized);
      _descriptionRecognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: raw,
          recognizer: recognizer,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(cursor),
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: theme.textTheme.bodyMedium));
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Text.rich(TextSpan(children: spans)),
    );
  }

  Future<void> _openDescriptionLink(String url) async {
    final internal = AtprotoLinkParser.parse(url);
    if (internal.postUri != null) {
      _openThreadByUri(internal.postUri!);
      return;
    }
    if (internal.profileActor != null) {
      _openProfileByActor(internal.profileActor!);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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

  void _showActionError(String title) {
    final details = AtprotoClientService().lastError;
    final message = details == null || details.isEmpty
        ? title
        : '$title\n$details';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: SelectableText(message),
        action: SnackBarAction(
          label: 'COPY',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
          },
        ),
      ),
    );
  }

  void _patchPostState(
    String uri,
    AtprotoFeedItem Function(AtprotoFeedItem current) mapper,
  ) {
    setState(() {
      _posts = _posts
          .map((item) => item.uri == uri ? mapper(item) : item)
          .toList();
      _mediaPosts = _mediaPosts
          .map((item) => item.uri == uri ? mapper(item) : item)
          .toList();
    });
  }

  void _openActorList(AtprotoActorListType type) {
    final profile = _profile;
    final actor = profile?.did.isNotEmpty == true
        ? profile!.did
        : (profile?.handle.isNotEmpty == true ? profile!.handle : widget.actor);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AtprotoActorListPage(actor: actor, type: type),
      ),
    );
  }

  Future<void> _openImagePreview(String imageUrl) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.broken_image,
                      color: Colors.white70,
                      size: 42,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }
}
