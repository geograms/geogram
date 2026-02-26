/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_profile_page.dart';
import 'atproto_thread_page.dart';

class AtprotoFollowingActivityPage extends StatefulWidget {
  const AtprotoFollowingActivityPage({super.key});

  @override
  State<AtprotoFollowingActivityPage> createState() =>
      _AtprotoFollowingActivityPageState();
}

class _AtprotoFollowingActivityPageState
    extends State<AtprotoFollowingActivityPage> {
  List<AtprotoFeedItem> _items = const [];
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
      final items = await AtprotoClientService().fetchFollowingActivity();
      if (!mounted) return;
      setState(() => _items = items);
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
      appBar: AppBar(title: const Text('Following Activity')),
      body: RefreshIndicator(
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
                    child: Text('Failed to load following activity: $_error'),
                  ),
                ),
              ),
            if (!_loading && _error == null && _items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('No activity from followed profiles yet'),
                ),
              ),
            if (_items.isNotEmpty)
              ..._items.map(
                (item) => AtprotoPostTile(
                  item: item,
                  onLike: () => _like(item),
                  onRepost: () => _repost(item),
                  onReply: () => _reply(item),
                  onOpenThread: () => _openThread(item),
                  onTapAuthor: () => _openAuthorProfile(item),
                  onOpenProfileActor: _openProfileByActor,
                  onOpenPostUri: _openThreadByUri,
                ),
              ),
          ],
        ),
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
      _patchItem(
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
      _patchItem(
        item.uri,
        (current) => current.copyWith(
          isRepostedByMe: true,
          repostCount: current.repostCount + 1,
        ),
      );
    });
  }

  void _reply(AtprotoFeedItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AtprotoThreadPage(rootPost: item)),
    );
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

  void _patchItem(
    String uri,
    AtprotoFeedItem Function(AtprotoFeedItem current) mapper,
  ) {
    setState(() {
      _items = _items
          .map((item) => item.uri == uri ? mapper(item) : item)
          .toList();
    });
  }
}
