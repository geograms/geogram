/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';
import '../models/atproto_profile.dart';
import 'atproto_profile_page.dart';

enum AtprotoActorListType { followers, following }

class AtprotoActorListPage extends StatefulWidget {
  final String actor;
  final AtprotoActorListType type;

  const AtprotoActorListPage({
    super.key,
    required this.actor,
    required this.type,
  });

  @override
  State<AtprotoActorListPage> createState() => _AtprotoActorListPageState();
}

class _AtprotoActorListPageState extends State<AtprotoActorListPage> {
  List<AtprotoProfile> _profiles = const [];
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
      final profiles = widget.type == AtprotoActorListType.followers
          ? await service.fetchFollowers(widget.actor, limit: 100)
          : await service.fetchFollowing(widget.actor, limit: 100);
      if (!mounted) return;
      setState(() => _profiles = profiles);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.type == AtprotoActorListType.followers
        ? 'Followers'
        : 'Following';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
                    child: Text('Failed to load list: $_error'),
                  ),
                ),
              ),
            if (!_loading && _error == null && _profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No profiles found')),
              ),
            ..._profiles.map(_buildTile),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(AtprotoProfile profile) {
    final actor = profile.did.isNotEmpty ? profile.did : profile.handle;
    final label = profile.displayName.isNotEmpty ? profile.displayName : actor;
    final subtitle = profile.handle.isNotEmpty ? '@${profile.handle}' : actor;
    final seed = label.trim().isNotEmpty ? label.trim() : actor;
    final initial = seed.isNotEmpty ? seed.substring(0, 1).toUpperCase() : '?';

    return ListTile(
      mouseCursor: SystemMouseCursors.click,
      leading: CircleAvatar(
        backgroundImage: profile.avatarUrl != null
            ? NetworkImage(profile.avatarUrl!)
            : null,
        child: profile.avatarUrl == null ? Text(initial) : null,
      ),
      title: Text(label, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, overflow: TextOverflow.ellipsis),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AtprotoProfilePage(actor: actor)),
        );
      },
    );
  }
}
