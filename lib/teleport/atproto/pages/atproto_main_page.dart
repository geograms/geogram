/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_settings_page.dart';

class AtprotoMainPage extends StatefulWidget {
  final String appPath;

  const AtprotoMainPage({super.key, required this.appPath});

  @override
  State<AtprotoMainPage> createState() => _AtprotoMainPageState();
}

class _AtprotoMainPageState extends State<AtprotoMainPage> {
  final TextEditingController _composer = TextEditingController();
  StreamSubscription<AtprotoClientEvent>? _sub;
  AtprotoFeedItem? _replyTarget;
  bool _isBootstrapping = true;
  String? _bootstrapError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _sub = AtprotoClientService().events.listen((event) {
      if (!mounted) return;
      setState(() {});

      if (event.type == AtprotoClientEventType.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('AT Proto: ${event.data}'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    });
  }

  Future<void> _bootstrap() async {
    final service = AtprotoClientService();
    setState(() {
      _isBootstrapping = true;
      _bootstrapError = null;
    });
    try {
      if (!service.config.enabled || service.isAuthenticated) {
        await service.syncFeed();
      } else {
        await service.login(
          identifier: service.config.identifier,
          password: service.config.password,
          allowAutoPasswordDiscovery: true,
        );
        await service.syncFeed();
      }
    } catch (e) {
      _bootstrapError = '$e';
    } finally {
      if (mounted) {
        setState(() {
          _isBootstrapping = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = AtprotoClientService();
    final feed = service.feed;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluesky / AT Proto'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => service.syncFeed(),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context)
                  .push(
                    MaterialPageRoute(
                      builder: (_) =>
                          AtprotoSettingsPage(appPath: widget.appPath),
                    ),
                  )
                  .then((_) {
                    if (mounted) setState(() {});
                  });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBootstrapping)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Expanded(child: Text('Starting Bluesky integration...')),
                    ],
                  ),
                ),
              ),
            )
          else if (_bootstrapError != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Could not initialize integration.'),
                      const SizedBox(height: 6),
                      Text(
                        _bootstrapError!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _bootstrap,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!service.isAuthenticated && !_isBootstrapping)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Connecting automatically...'),
                ),
              ),
            ),
          Expanded(
            child: feed.isEmpty
                ? const Center(child: Text('No posts yet'))
                : ListView.builder(
                    itemCount: feed.length,
                    itemBuilder: (context, index) {
                      final item = feed[index];
                      return AtprotoPostTile(
                        item: item,
                        onLike: () => service.likePost(item),
                        onRepost: () => service.repost(item),
                        onReply: () => setState(() => _replyTarget = item),
                      );
                    },
                  ),
          ),
          _buildComposer(service),
        ],
      ),
    );
  }

  Widget _buildComposer(AtprotoClientService service) {
    return Material(
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
                      onPressed: () => setState(() => _replyTarget = null),
                    ),
                  ],
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Write a post...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: service.isAuthenticated && !_isBootstrapping
                        ? _publish
                        : null,
                    child: const Text('Post'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _publish() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;

    final ok = await AtprotoClientService().publishPost(
      text,
      replyTo: _replyTarget,
    );
    if (!mounted) return;

    if (ok) {
      _composer.clear();
      setState(() => _replyTarget = null);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to publish post')));
    }
  }
}
