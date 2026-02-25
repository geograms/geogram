/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_profile_page.dart';

class AtprotoThreadPage extends StatefulWidget {
  final AtprotoFeedItem rootPost;

  const AtprotoThreadPage({super.key, required this.rootPost});

  @override
  State<AtprotoThreadPage> createState() => _AtprotoThreadPageState();
}

class _AtprotoThreadPageState extends State<AtprotoThreadPage> {
  final TextEditingController _composer = TextEditingController();
  List<AtprotoFeedItem> _replies = const [];
  AtprotoFeedItem? _replyTarget;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReplies();
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final replies = await AtprotoClientService().fetchReplies(
        widget.rootPost.uri,
      );
      if (!mounted) return;
      setState(() => _replies = replies);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final composerLength = _composer.text.trim().length;
    final canPublish = composerLength > 0 && composerLength <= 300;

    return Scaffold(
      appBar: AppBar(title: const Text('Post Thread')),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadReplies,
              child: ListView(
                children: [
                  AtprotoPostTile(
                    item: widget.rootPost,
                    onLike: () => _like(widget.rootPost),
                    onRepost: () => _repost(widget.rootPost),
                    onReply: () =>
                        setState(() => _replyTarget = widget.rootPost),
                    onTapAuthor: () => _openAuthorProfile(widget.rootPost),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                    child: Text(
                      'Replies',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
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
                          child: Text('Failed to load replies: $_error'),
                        ),
                      ),
                    ),
                  if (!_loading && _error == null && _replies.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No replies yet')),
                    ),
                  if (_replies.isNotEmpty)
                    ..._replies.map(
                      (item) => AtprotoPostTile(
                        item: item,
                        compact: true,
                        onLike: () => _like(item),
                        onRepost: () => _repost(item),
                        onReply: () => setState(() => _replyTarget = item),
                        onOpenThread: () => _openThread(item),
                        onTapAuthor: () => _openAuthorProfile(item),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Material(
            elevation: 8,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyTarget != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Replying to @${_replyTarget!.authorHandle}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () =>
                                setState(() => _replyTarget = null),
                          ),
                        ],
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _composer,
                            onChanged: (_) => setState(() {}),
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Write a reply...',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          children: [
                            Text(
                              '$composerLength/300',
                              style: const TextStyle(fontSize: 11),
                            ),
                            const SizedBox(height: 4),
                            FilledButton(
                              onPressed: canPublish ? _publish : null,
                              child: const Text('Reply'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _like(AtprotoFeedItem item) {
    AtprotoClientService().likePost(item).then((ok) {
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not like this reply')),
        );
      }
    });
  }

  void _repost(AtprotoFeedItem item) {
    AtprotoClientService().repost(item).then((ok) {
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not repost this reply')),
        );
      }
    });
  }

  void _openAuthorProfile(AtprotoFeedItem item) {
    final actor = item.authorDid.startsWith('did:')
        ? item.authorDid
        : item.authorHandle;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AtprotoProfilePage(actor: actor)));
  }

  void _openThread(AtprotoFeedItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AtprotoThreadPage(rootPost: item)),
    );
  }

  Future<void> _publish() async {
    final text = _composer.text.trim();
    if (text.isEmpty || text.length > 300) return;
    final target = _replyTarget ?? widget.rootPost;
    final ok = await AtprotoClientService().publishPost(text, replyTo: target);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to publish reply')));
      return;
    }
    _composer.clear();
    setState(() => _replyTarget = null);
    await _loadReplies();
  }
}
