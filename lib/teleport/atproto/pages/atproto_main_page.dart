/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/i18n_service.dart';
import '../atproto_client_service.dart';
import '../models/atproto_feed_item.dart';
import '../widgets/atproto_post_tile.dart';
import 'atproto_following_activity_page.dart';
import 'atproto_profile_page.dart';
import 'atproto_search_page.dart';
import 'atproto_settings_page.dart';
import 'atproto_thread_page.dart';

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
    final composerLength = _composer.text.trim().length;
    final canPublish =
        service.isAuthenticated &&
        !_isBootstrapping &&
        composerLength > 0 &&
        composerLength <= 300;

    return Scaffold(
      appBar: AppBar(
        title: Text(I18nService().t('atproto_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: I18nService().t('atproto_refresh_tooltip'),
            onPressed: () => service.syncFeed(),
          ),
          IconButton(
            icon: const Icon(Icons.group),
            tooltip: I18nService().t('atproto_following_activity_tooltip'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AtprotoFollowingActivityPage(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: I18nService().t('atproto_search_network_tooltip'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AtprotoSearchPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: I18nService().t('atproto_my_profile_tooltip'),
            onPressed: _openMyProfile,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: I18nService().t('atproto_settings_tooltip'),
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
            Padding(
              padding: const EdgeInsets.all(12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(I18nService().t('atproto_starting_integration'))),
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
                      Text(I18nService().t('atproto_init_error_title')),
                      const SizedBox(height: 6),
                      Text(
                        _bootstrapError!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _bootstrap,
                        child: Text(I18nService().t('atproto_retry_btn')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: _buildStatusBanner(context, service),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: service.syncFeed,
              child: feed.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 140),
                        Center(child: Text(I18nService().t('atproto_no_posts'))),
                      ],
                    )
                  : ListView.builder(
                      itemCount: feed.length,
                      itemBuilder: (context, index) {
                        final item = feed[index];
                        return AtprotoPostTile(
                          item: item,
                          onLike: () => _toggleLike(item),
                          onRepost: () => _toggleRepost(item),
                          onReply: () => setState(() => _replyTarget = item),
                          onOpenThread: () => _openThread(item),
                          onTapAuthor: () => _openAuthorProfile(item),
                          onOpenProfileActor: _openProfileByActor,
                          onOpenPostUri: _openThreadByUri,
                        );
                      },
                    ),
            ),
          ),
          _buildComposer(service, canPublish, composerLength),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(
    BuildContext context,
    AtprotoClientService service,
  ) {
    final theme = Theme.of(context);
    final authenticated = service.isAuthenticated;
    final icon = authenticated ? Icons.verified_user : Icons.public;
    final color = authenticated
        ? Colors.green.shade700
        : theme.colorScheme.primary;
    final text = authenticated
        ? I18nService().t('atproto_connected_as', params: [service.session?.handle ?? service.config.identifier])
        : I18nService().t('atproto_readonly_feed');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(
    AtprotoClientService service,
    bool canPublish,
    int composerLength,
  ) {
    final overLimit = composerLength > 300;

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
                        I18nService().t('atproto_replying_to', params: [_replyTarget!.authorHandle]),
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
                      onChanged: (_) => setState(() {}),
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: I18nService().t('atproto_write_post_hint'),
                        helperText: overLimit
                            ? I18nService().t('atproto_post_too_long')
                            : null,
                        helperStyle: TextStyle(
                          color: overLimit ? Colors.red.shade700 : null,
                        ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    children: [
                      Text(
                        '$composerLength/300',
                        style: TextStyle(
                          fontSize: 11,
                          color: overLimit ? Colors.red.shade700 : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FilledButton(
                        onPressed: canPublish ? _publish : null,
                        child: Text(I18nService().t('atproto_post_btn')),
                      ),
                    ],
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
    if (text.isEmpty || text.length > 300) return;

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
      ).showSnackBar(SnackBar(content: Text(I18nService().t('atproto_publish_failed'))));
    }
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

  void _toggleLike(AtprotoFeedItem item) {
    AtprotoClientService().likePost(item).then((ok) {
      if (!ok && mounted) {
        _showActionError(I18nService().t('atproto_like_failed'));
      }
    });
  }

  void _toggleRepost(AtprotoFeedItem item) {
    AtprotoClientService().repost(item).then((ok) {
      if (!ok && mounted) {
        _showActionError(I18nService().t('atproto_repost_failed'));
      }
    });
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

  void _openMyProfile() {
    final service = AtprotoClientService();
    final actor = service.session?.did.isNotEmpty == true
        ? service.session!.did
        : (service.session?.handle.isNotEmpty == true
              ? service.session!.handle
              : service.config.identifier);
    if (actor.trim().isEmpty) return;
    _openProfileByActor(actor.trim());
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
}
