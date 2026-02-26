/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../models/atproto_profile.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_profile_page.dart';
import 'atproto_thread_page.dart';

class AtprotoSearchPage extends StatefulWidget {
  const AtprotoSearchPage({super.key});

  @override
  State<AtprotoSearchPage> createState() => _AtprotoSearchPageState();
}

class _AtprotoSearchPageState extends State<AtprotoSearchPage> {
  final TextEditingController _query = TextEditingController();
  List<AtprotoProfile> _people = const [];
  List<AtprotoFeedItem> _posts = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) {
      setState(() {
        _people = const [];
        _posts = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = AtprotoClientService();
      final peopleFuture = service.searchPeople(q, limit: 25);
      final postsFuture = service.searchPosts(q, limit: 25);
      final results = await Future.wait([peopleFuture, postsFuture]);
      if (!mounted) return;
      setState(() {
        _people = results[0] as List<AtprotoProfile>;
        _posts = results[1] as List<AtprotoFeedItem>;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search Network')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    onSubmitted: (_) => _search(),
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Search people and posts...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : _search,
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('Search failed: $_error'),
                      ),
                    ),
                  ),
                if (!_loading &&
                    _error == null &&
                    _query.text.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                    child: Text(
                      '${_people.length} people • ${_posts.length} posts',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_people.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
                    child: Text(
                      'People',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ..._people.map((p) => _personTile(p)),
                ],
                if (_posts.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Text(
                      'Posts',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ..._posts.map(
                    (item) => AtprotoPostTile(
                      item: item,
                      onLike: () => _like(item),
                      onRepost: () => _repost(item),
                      onReply: () => _openThread(item),
                      onOpenThread: () => _openThread(item),
                      onTapAuthor: () => _openAuthor(item),
                      onOpenProfileActor: _openProfileByActor,
                      onOpenPostUri: _openThreadByUri,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _personTile(AtprotoProfile profile) {
    final actor = profile.did.isNotEmpty ? profile.did : profile.handle;
    final label = profile.displayName.isNotEmpty
        ? profile.displayName
        : profile.handle;
    final initial = label.isNotEmpty
        ? label.substring(0, 1).toUpperCase()
        : '?';
    return ListTile(
      mouseCursor: SystemMouseCursors.click,
      onTap: actor.isEmpty ? null : () => _openProfileByActor(actor),
      leading: CircleAvatar(
        backgroundImage: profile.avatarUrl != null
            ? NetworkImage(profile.avatarUrl!)
            : null,
        child: profile.avatarUrl == null ? Text(initial) : null,
      ),
      title: Text(label),
      subtitle: Text('@${profile.handle}'),
      trailing: profile.isFollowedByMe
          ? const Icon(Icons.check, size: 18)
          : IconButton(
              tooltip: 'Follow',
              icon: const Icon(Icons.person_add_alt_1),
              onPressed: () => _follow(profile),
            ),
    );
  }

  void _openAuthor(AtprotoFeedItem item) {
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

  void _openThread(AtprotoFeedItem item) {
    final target = item.rootUri?.isNotEmpty == true
        ? item.rootUri!.trim()
        : item.uri;
    _openThreadByUri(target);
  }

  void _openThreadByUri(String postUri) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AtprotoThreadPage(rootPostUri: postUri),
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
      _patchPost(
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
      _patchPost(
        item.uri,
        (current) => current.copyWith(
          isRepostedByMe: true,
          repostCount: current.repostCount + 1,
        ),
      );
    });
  }

  void _follow(AtprotoProfile profile) {
    final actor = profile.did.isNotEmpty ? profile.did : profile.handle;
    if (actor.isEmpty) return;
    AtprotoClientService().followActor(actor).then((ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Followed @${profile.handle}' : 'Could not follow profile',
          ),
        ),
      );
      if (ok) {
        setState(() {
          _people = _people
              .map(
                (p) => p.did == profile.did
                    ? AtprotoProfile(
                        did: p.did,
                        handle: p.handle,
                        displayName: p.displayName,
                        description: p.description,
                        avatarUrl: p.avatarUrl,
                        bannerUrl: p.bannerUrl,
                        followersCount: p.followersCount,
                        followsCount: p.followsCount,
                        postsCount: p.postsCount,
                        isFollowedByMe: true,
                      )
                    : p,
              )
              .toList();
        });
      }
    });
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

  void _patchPost(
    String uri,
    AtprotoFeedItem Function(AtprotoFeedItem current) mapper,
  ) {
    setState(() {
      _posts = _posts
          .map((item) => item.uri == uri ? mapper(item) : item)
          .toList();
    });
  }
}
