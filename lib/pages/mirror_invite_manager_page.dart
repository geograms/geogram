library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mirror_config.dart';
import '../models/mirror_invitation.dart';
import '../services/mirror_config_service.dart';
import '../services/mirror_invitation_service.dart';

class MirrorInviteManagerPage extends StatefulWidget {
  const MirrorInviteManagerPage({super.key});

  @override
  State<MirrorInviteManagerPage> createState() =>
      _MirrorInviteManagerPageState();
}

class _MirrorInviteManagerPageState extends State<MirrorInviteManagerPage> {
  final MirrorInvitationService _inviteService =
      MirrorInvitationService.instance;
  final MirrorConfigService _configService = MirrorConfigService.instance;

  bool _loading = true;
  List<MirrorInvitation> _invites = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _inviteService.initialize();
    await _configService.loadConfig();
    final invites = await _inviteService.loadInvitations();
    if (!mounted) return;
    setState(() {
      _invites = invites;
      _loading = false;
    });
  }

  Future<void> _createInvite() async {
    final invite = await _inviteService.createInvite();
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: invite.code));
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Invite created: ${invite.code}')));
  }

  Future<void> _denyInvite(String code) async {
    await _inviteService.denyInvite(code);
    await _load();
  }

  Future<void> _revokeAccess(String npub) async {
    await _inviteService.revokeAccess(npub);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = _invites.where((invite) => invite.isPending).toList();
    final peers = _configService.config?.peers ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Invitations')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createInvite,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Generate invite'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  _buildSectionHeader(theme, 'Current invitations'),
                  if (pending.isEmpty)
                    _buildEmptyState(
                      theme,
                      Icons.badge_outlined,
                      'No pending invitations',
                      'Generate a code to let another device join.',
                    )
                  else
                    ...pending.map((invite) => _buildInviteTile(invite)),
                  const Divider(height: 32),
                  _buildSectionHeader(theme, 'People with access'),
                  if (peers.isEmpty)
                    _buildEmptyState(
                      theme,
                      Icons.devices,
                      'No devices yet',
                      'Accepted devices will appear here.',
                    )
                  else
                    ...peers.map(_buildPeerTile),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    ThemeData theme,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(icon, size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInviteTile(MirrorInvitation invite) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.confirmation_number_outlined),
          title: Text(
            invite.code,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          subtitle: Text(
            'Created ${invite.createdAt.toLocal()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'copy') {
                await Clipboard.setData(ClipboardData(text: invite.code));
              } else if (value == 'deny') {
                await _denyInvite(invite.code);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'copy',
                child: Row(
                  children: [
                    Icon(Icons.copy, size: 18),
                    SizedBox(width: 8),
                    Text('Copy code'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'deny',
                child: Row(
                  children: [
                    Icon(Icons.block, size: 18),
                    SizedBox(width: 8),
                    Text('Deny'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPeerTile(MirrorPeer peer) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.devices),
          title: Text(peer.name),
          subtitle: Text(peer.callsign),
          trailing: IconButton(
            tooltip: 'Revoke access',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _revokeAccess(peer.npub),
          ),
        ),
      ),
    );
  }
}
