/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../widgets/atproto_post_tile.dart';

class AtprotoThreadPage extends StatefulWidget {
  final AtprotoFeedItem rootPost;

  const AtprotoThreadPage({super.key, required this.rootPost});

  @override
  State<AtprotoThreadPage> createState() => _AtprotoThreadPageState();
}

class _AtprotoThreadPageState extends State<AtprotoThreadPage> {
  List<AtprotoFeedItem> _replies = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReplies();
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
    return Scaffold(
      appBar: AppBar(title: const Text('Post Thread')),
      body: RefreshIndicator(
        onRefresh: _loadReplies,
        child: ListView(
          children: [
            AtprotoPostTile(item: widget.rootPost),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Text(
                'Replies',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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
                ),
              ),
          ],
        ),
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
}
