/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_channel.dart';
import '../services/app_service.dart';
import '../services/chat_service.dart';
import '../services/devices_service.dart';
import '../services/distributed_chat_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import 'add_member_page.dart';

/// Page for managing chat room members and roles (for restricted rooms)
class RoomManagementPage extends StatefulWidget {
  final ChatChannel channel;

  const RoomManagementPage({Key? key, required this.channel}) : super(key: key);

  @override
  State<RoomManagementPage> createState() => _RoomManagementPageState();
}

class _RoomManagementPageState extends State<RoomManagementPage>
    with SingleTickerProviderStateMixin {
  final ChatService _chatService = ChatService();
  final DevicesService _devicesService = DevicesService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  DistributedChatService? _distributedChatService;

  late TabController _tabController;
  bool _isLoading = false;
  ChatChannelConfig? _config;
  String? _userNpub;
  String? _userRole;

  bool get _isDistributedRoom => widget.channel.config?.isDistributed ?? false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initializeDistributedService();
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _initializeDistributedService() {
    if (!_isDistributedRoom) {
      return;
    }

    final chatApp = AppService().getAppByType('chat');
    final storage = AppService().profileStorage;
    final profile = _profileService.getProfile();
    if (chatApp?.storagePath == null || storage == null) {
      return;
    }

    _distributedChatService = DistributedChatService(
      appPath: chatApp!.storagePath!,
      storage: storage,
      profileCallsign: profile.callsign,
      profileNpub: profile.npub,
      profileNsec: profile.nsec.isNotEmpty ? profile.nsec : null,
    );
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final profile = _profileService.getProfile();
      _userNpub = profile.npub;

      ChatChannel channel;
      if (_isDistributedRoom && _distributedChatService != null) {
        channel =
            await _distributedChatService!.getRoom(widget.channel.id) ??
            widget.channel;
      } else {
        await _chatService.refreshChannels();
        channel = _chatService.channels.firstWhere(
          (c) => c.id == widget.channel.id,
          orElse: () => widget.channel,
        );
      }

      _config = channel.config;
      _userRole = _determineUserRole();
    } catch (e) {
      _showError('Failed to load room data: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _determineUserRole() {
    if (_config == null || _userNpub == null) return 'none';
    if (_config!.isOwner(_userNpub)) return 'owner';
    if (_config!.isAdmin(_userNpub)) return 'admin';
    if (_config!.isModerator(_userNpub)) return 'moderator';
    if (_config!.isMember(_userNpub)) return 'member';
    return 'none';
  }

  bool get _canManageMembers => _config?.canManageMembers(_userNpub) ?? false;

  bool get _canManageRoles => _config?.canManageRoles(_userNpub) ?? false;

  bool get _canManageAdmins => _config?.canManageAdmins(_userNpub) ?? false;

  bool get _canBan => _config?.canBan(_userNpub) ?? false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.channel.name),
        actions: [
          if (_isDistributedRoom && (_config?.canAccess(_userNpub) ?? false))
            IconButton(
              onPressed: _showInviteDialog,
              icon: const Icon(Icons.link),
              tooltip: 'Copy invite link',
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(icon: const Icon(Icons.people), text: _i18n.t('members')),
            Tab(
              icon: const Icon(Icons.pending_actions),
              text: _i18n.t('pending'),
            ),
            Tab(icon: const Icon(Icons.block), text: _i18n.t('banned')),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Room info header
                _buildRoomInfoHeader(theme),
                // Tab views
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildMembersTab(theme),
                      _buildPendingTab(theme),
                      _buildBannedTab(theme),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: _isDistributedRoom
          ? ((_config?.canAccess(_userNpub) ?? false)
                ? FloatingActionButton(
                    onPressed: _showInviteDialog,
                    child: const Icon(Icons.link),
                  )
                : null)
          : (_canManageMembers
                ? FloatingActionButton(
                    onPressed: _showAddMemberDialog,
                    child: const Icon(Icons.person_add),
                  )
                : null),
    );
  }

  Widget _buildRoomInfoHeader(ThemeData theme) {
    final visibility = _config?.visibility ?? 'PUBLIC';
    final isRestricted = visibility == 'RESTRICTED';
    final canChangeVisibility =
        !_isDistributedRoom &&
        _canManageAdmins; // Only owner can change visibility

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if ((_config?.icon ?? '').isNotEmpty) ...[
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _config!.icon!,
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              // Visibility badge - tappable if user can change it
              InkWell(
                onTap: canChangeVisibility ? _showVisibilityDialog : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isRestricted
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                    border: canChangeVisibility
                        ? Border.all(color: theme.colorScheme.outline)
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isRestricted ? Icons.lock : Icons.public,
                        size: 18,
                        color: isRestricted
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isDistributedRoom
                            ? 'Decentralized room'
                            : (isRestricted
                                  ? _i18n.t('restricted_room')
                                  : _i18n.t('public_room')),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isRestricted
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (canChangeVisibility) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.edit,
                          size: 14,
                          color: isRestricted
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // User's role badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: _getRoleColor(theme).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _getRoleColor(theme)),
                ),
                child: Text(
                  _i18n.t('role_$_userRole'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: _getRoleColor(theme),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (_config?.description != null &&
              _config!.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _config!.description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_isDistributedRoom) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildStatChip(
                  theme,
                  Icons.hub,
                  _config?.roomState ?? 'active',
                  'State',
                ),
                _buildStatChip(
                  theme,
                  Icons.vpn_key,
                  _config?.joinPolicy ?? 'approval_required',
                  'Join policy',
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // Stats row
          Row(
            children: [
              _buildStatChip(
                theme,
                Icons.person,
                '${_config?.members.length ?? 0}',
                _i18n.t('members'),
              ),
              const SizedBox(width: 12),
              _buildStatChip(
                theme,
                Icons.shield,
                '${_config?.moderatorNpubs.length ?? 0}',
                _i18n.t('moderators'),
              ),
              const SizedBox(width: 12),
              _buildStatChip(
                theme,
                Icons.admin_panel_settings,
                '${_config?.admins.length ?? 0}',
                _i18n.t('admins'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(
    ThemeData theme,
    IconData icon,
    String count,
    String label,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          count,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Color _getRoleColor(ThemeData theme) {
    switch (_userRole) {
      case 'owner':
        return Colors.amber.shade700;
      case 'admin':
        return Colors.purple;
      case 'moderator':
        return Colors.blue;
      case 'member':
        return Colors.green;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  Widget _buildMembersTab(ThemeData theme) {
    if (_config == null) {
      return Center(child: Text(_i18n.t('no_data')));
    }

    // Build list of all members with their roles
    final List<_MemberInfo> allMembers = [];

    // Add owner
    if (_config!.owner != null) {
      allMembers.add(
        _MemberInfo(
          npub: _config!.owner!,
          role: 'owner',
          callsign: _npubToCallsign(_config!.owner!),
          nickname: _getNicknameForNpub(_config!.owner!),
        ),
      );
    }

    // Add admins
    for (final npub in _config!.admins) {
      if (npub != _config!.owner) {
        allMembers.add(
          _MemberInfo(
            npub: npub,
            role: 'admin',
            callsign: _npubToCallsign(npub),
            nickname: _getNicknameForNpub(npub),
          ),
        );
      }
    }

    // Add moderators
    for (final npub in _config!.moderatorNpubs) {
      if (!_config!.admins.contains(npub) && npub != _config!.owner) {
        allMembers.add(
          _MemberInfo(
            npub: npub,
            role: 'moderator',
            callsign: _npubToCallsign(npub),
            nickname: _getNicknameForNpub(npub),
          ),
        );
      }
    }

    // Add regular members
    for (final npub in _config!.members) {
      if (!_config!.moderatorNpubs.contains(npub) &&
          !_config!.admins.contains(npub) &&
          npub != _config!.owner) {
        allMembers.add(
          _MemberInfo(
            npub: npub,
            role: 'member',
            callsign: _npubToCallsign(npub),
            nickname: _getNicknameForNpub(npub),
          ),
        );
      }
    }

    if (allMembers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('no_members'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        itemCount: allMembers.length,
        itemBuilder: (context, index) {
          final member = allMembers[index];
          return _buildMemberTile(theme, member);
        },
      ),
    );
  }

  Widget _buildMemberTile(ThemeData theme, _MemberInfo member) {
    final isCurrentUser = member.npub == _userNpub;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _getMemberRoleColor(
          theme,
          member.role,
        ).withOpacity(0.1),
        child: Icon(
          _getMemberRoleIcon(member.role),
          color: _getMemberRoleColor(theme, member.role),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              member.displayName,
              style: TextStyle(
                fontWeight: isCurrentUser ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isCurrentUser) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _i18n.t('you'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        _truncateNpub(member.npub),
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: _buildMemberActions(theme, member),
      onTap: () => _showMemberDetails(member),
    );
  }

  Widget? _buildMemberActions(ThemeData theme, _MemberInfo member) {
    final isCurrentUser = member.npub == _userNpub;
    if (isCurrentUser) return null;

    // Owner cannot be modified
    if (member.role == 'owner') return null;

    final List<PopupMenuEntry<String>> menuItems = [];

    // Role management options
    if (_canManageRoles) {
      if (member.role == 'member') {
        menuItems.add(
          PopupMenuItem(
            value: 'promote_moderator',
            child: ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: Text(_i18n.t('promote_to_moderator')),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        );
      }
      if (member.role == 'moderator') {
        menuItems.add(
          PopupMenuItem(
            value: 'demote_member',
            child: ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: Text(_i18n.t('demote_to_member')),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        );
      }
    }

    // Admin promotion/demotion (owner only)
    if (_canManageAdmins) {
      if (member.role == 'moderator') {
        menuItems.add(
          PopupMenuItem(
            value: 'promote_admin',
            child: ListTile(
              leading: const Icon(Icons.admin_panel_settings),
              title: Text(_i18n.t('promote_to_admin')),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        );
      }
      if (member.role == 'admin') {
        menuItems.add(
          PopupMenuItem(
            value: 'demote_moderator',
            child: ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: Text(_i18n.t('demote_to_moderator')),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        );
      }
    }

    // Member removal and ban
    if (_canManageMembers && member.role != 'admin') {
      if (menuItems.isNotEmpty) {
        menuItems.add(const PopupMenuDivider());
      }
      menuItems.add(
        PopupMenuItem(
          value: 'remove',
          child: ListTile(
            leading: Icon(Icons.person_remove, color: theme.colorScheme.error),
            title: Text(
              _i18n.t('remove_member'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      );
    }

    if (_canBan && member.role != 'admin') {
      menuItems.add(
        PopupMenuItem(
          value: 'ban',
          child: ListTile(
            leading: Icon(Icons.block, color: theme.colorScheme.error),
            title: Text(
              _i18n.t('ban_user'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      );
    }

    if (menuItems.isEmpty) return null;

    return PopupMenuButton<String>(
      onSelected: (action) => _handleMemberAction(action, member),
      itemBuilder: (context) => menuItems,
    );
  }

  Widget _buildPendingTab(ThemeData theme) {
    if (_config == null) {
      return Center(child: Text(_i18n.t('no_data')));
    }

    final applicants = _config!.pendingApplicants;

    if (applicants.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.pending_actions,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('no_pending_applications'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        itemCount: applicants.length,
        itemBuilder: (context, index) {
          final applicant = applicants[index];
          return _buildApplicantTile(theme, applicant);
        },
      ),
    );
  }

  Widget _buildApplicantTile(ThemeData theme, MembershipApplication applicant) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person_add,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        applicant.callsign ?? _npubToCallsign(applicant.npub),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _truncateNpub(applicant.npub),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _formatDate(applicant.appliedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (applicant.message != null && applicant.message!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.format_quote,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        applicant.message!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_canManageMembers) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _rejectApplication(applicant),
                    icon: const Icon(Icons.close),
                    label: Text(_i18n.t('reject')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => _approveApplication(applicant),
                    icon: const Icon(Icons.check),
                    label: Text(_i18n.t('approve')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBannedTab(ThemeData theme) {
    if (_config == null) {
      return Center(child: Text(_i18n.t('no_data')));
    }

    final banned = _config!.banned;

    if (banned.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.block,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('no_banned_users'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        itemCount: banned.length,
        itemBuilder: (context, index) {
          final npub = banned[index];
          final callsign = _npubToCallsign(npub);
          final nickname = _getNicknameForNpub(npub);
          final displayName = _getDisplayName(callsign, nickname);
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.errorContainer,
              child: Icon(
                Icons.block,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            title: Text(displayName),
            subtitle: Text(
              _truncateNpub(npub),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            trailing: _canBan
                ? IconButton(
                    icon: const Icon(Icons.restore),
                    onPressed: () => _unbanUser(npub),
                    tooltip: _i18n.t('unban'),
                  )
                : null,
          );
        },
      ),
    );
  }

  void _showMemberDetails(_MemberInfo member) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(member.displayName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (member.nickname != null && member.nickname!.isNotEmpty) ...[
              _buildDetailRow(_i18n.t('nickname'), member.nickname!),
              const SizedBox(height: 8),
            ],
            _buildDetailRow(_i18n.t('callsign'), member.callsign),
            const SizedBox(height: 8),
            _buildDetailRow(_i18n.t('role'), _i18n.t('role_${member.role}')),
            const SizedBox(height: 8),
            _buildDetailRow(_i18n.t('npub'), member.npub),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('close')),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const SizedBox(height: 4),
        SelectableText(
          value,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _showAddMemberDialog() async {
    if (_config == null || _userNpub == null) return;
    if (_isDistributedRoom) {
      await _showInviteDialog();
      return;
    }

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => AddMemberPage(
          channel: widget.channel,
          userNpub: _userNpub!,
          config: _config!,
        ),
      ),
    );

    // Reload data if members were added
    if (result == true) {
      await _loadData();
    }
  }

  Future<void> _showInviteDialog() async {
    if (!_isDistributedRoom || _distributedChatService == null) {
      return;
    }

    try {
      final invite = await _distributedChatService!.createInvite(
        widget.channel.id,
        oneTime: true,
      );
      final encodedInvite = invite.encode();
      if (!mounted) {
        return;
      }

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('One-time invite link'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Works once. Share with the person you want to add — the first joiner is auto-admitted, the link then stops working.',
                ),
                const SizedBox(height: 12),
                SelectableText(encodedInvite),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_i18n.t('close')),
            ),
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: encodedInvite));
                Navigator.pop(context);
                _showSuccess('Invite link copied');
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError('Failed to create invite: $e');
    }
  }

  Future<void> _handleMemberAction(String action, _MemberInfo member) async {
    switch (action) {
      case 'promote_moderator':
        await _promoteToModerator(member.npub);
        break;
      case 'promote_admin':
        await _promoteToAdmin(member.npub);
        break;
      case 'demote_member':
      case 'demote_moderator':
        await _demote(member.npub);
        break;
      case 'remove':
        await _removeMember(member.npub);
        break;
      case 'ban':
        await _banUser(member.npub);
        break;
    }
  }

  Future<void> _promoteToModerator(String npub) async {
    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.promoteToModerator(
          widget.channel.id,
          npub,
        );
      } else {
        await _chatService.promoteToModerator(
          widget.channel.id,
          _userNpub!,
          npub,
        );
      }
      _showSuccess(_i18n.t('promoted_to_moderator'));
      await _loadData();
    } catch (e) {
      _showError('Failed to promote: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _promoteToAdmin(String npub) async {
    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.promoteToAdmin(widget.channel.id, npub);
      } else {
        await _chatService.promoteToAdmin(widget.channel.id, _userNpub!, npub);
      }
      _showSuccess(_i18n.t('promoted_to_admin'));
      await _loadData();
    } catch (e) {
      _showError('Failed to promote: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _demote(String npub) async {
    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        final isAdmin = _config?.admins.contains(npub) ?? false;
        if (isAdmin) {
          await _distributedChatService!.demoteAdmin(widget.channel.id, npub);
        } else {
          await _distributedChatService!.demoteModerator(
            widget.channel.id,
            npub,
          );
        }
      } else {
        await _chatService.demote(widget.channel.id, _userNpub!, npub);
      }
      _showSuccess(_i18n.t('user_demoted'));
      await _loadData();
    } catch (e) {
      _showError('Failed to demote: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _removeMember(String npub) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('remove_member')),
        content: Text(_i18n.t('remove_member_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('remove')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.removeMember(widget.channel.id, npub);
      } else {
        await _chatService.removeMember(widget.channel.id, _userNpub!, npub);
      }
      _showSuccess(_i18n.t('member_removed'));
      await _loadData();
    } catch (e) {
      _showError('Failed to remove member: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _banUser(String npub) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('ban_user')),
        content: Text(_i18n.t('ban_user_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('ban')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.banMember(widget.channel.id, npub);
      } else {
        await _chatService.banMember(widget.channel.id, _userNpub!, npub);
      }
      _showSuccess(_i18n.t('user_banned'));
      await _loadData();
    } catch (e) {
      _showError('Failed to ban user: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _unbanUser(String npub) async {
    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.unbanMember(widget.channel.id, npub);
      } else {
        await _chatService.unbanMember(widget.channel.id, _userNpub!, npub);
      }
      _showSuccess(_i18n.t('user_unbanned'));
      await _loadData();
    } catch (e) {
      _showError('Failed to unban user: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _approveApplication(MembershipApplication applicant) async {
    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.approveApplicant(
          widget.channel.id,
          applicant.npub,
        );
      } else {
        await _chatService.approveApplication(
          widget.channel.id,
          _userNpub!,
          applicant.npub,
        );
      }
      _showSuccess(_i18n.t('application_approved'));
      await _loadData();
    } catch (e) {
      _showError('Failed to approve: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _rejectApplication(MembershipApplication applicant) async {
    setState(() => _isLoading = true);

    try {
      if (_isDistributedRoom) {
        await _distributedChatService!.rejectApplicant(
          widget.channel.id,
          applicant.npub,
        );
      } else {
        await _chatService.rejectApplication(
          widget.channel.id,
          _userNpub!,
          applicant.npub,
        );
      }
      _showSuccess(_i18n.t('application_rejected'));
      await _loadData();
    } catch (e) {
      _showError('Failed to reject: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _npubToCallsign(String npub) {
    // Generate a callsign-like identifier from npub
    if (npub.length < 10) return npub;
    final chars = npub.substring(5, 11).toUpperCase();
    return 'X$chars';
  }

  /// Look up device by npub and return its nickname if available
  String? _getNicknameForNpub(String npub) {
    final devices = _devicesService.getAllDevices();
    for (final device in devices) {
      if (device.npub == npub) {
        return device.nickname;
      }
    }
    return null;
  }

  /// Get display name for member: "Nickname (CALLSIGN)" or just "CALLSIGN"
  String _getDisplayName(String callsign, String? nickname) {
    if (nickname != null && nickname.isNotEmpty) {
      return '$nickname ($callsign)';
    }
    return callsign;
  }

  String _truncateNpub(String npub) {
    if (npub.length <= 20) return npub;
    return '${npub.substring(0, 12)}...${npub.substring(npub.length - 8)}';
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Color _getMemberRoleColor(ThemeData theme, String role) {
    switch (role) {
      case 'owner':
        return Colors.amber.shade700;
      case 'admin':
        return Colors.purple;
      case 'moderator':
        return Colors.blue;
      case 'member':
        return Colors.green;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  IconData _getMemberRoleIcon(String role) {
    switch (role) {
      case 'owner':
        return Icons.star;
      case 'admin':
        return Icons.admin_panel_settings;
      case 'moderator':
        return Icons.shield;
      case 'member':
        return Icons.person;
      default:
        return Icons.person_outline;
    }
  }

  Future<void> _showVisibilityDialog() async {
    final currentVisibility = _config?.visibility ?? 'PUBLIC';
    final theme = Theme.of(context);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('change_visibility')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _i18n.t('change_visibility_warning'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // Public option
            RadioListTile<String>(
              value: 'PUBLIC',
              groupValue: currentVisibility,
              onChanged: (value) => Navigator.pop(context, value),
              title: Row(
                children: [
                  const Icon(Icons.public, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('public_room')),
                ],
              ),
              subtitle: Text(_i18n.t('public_room_description')),
            ),
            // Restricted option
            RadioListTile<String>(
              value: 'RESTRICTED',
              groupValue: currentVisibility,
              onChanged: (value) => Navigator.pop(context, value),
              title: Row(
                children: [
                  const Icon(Icons.lock, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('restricted_room')),
                ],
              ),
              subtitle: Text(_i18n.t('restricted_room_description')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );

    if (result != null && result != currentVisibility) {
      await _changeVisibility(result);
    }
  }

  Future<void> _changeVisibility(String newVisibility) async {
    if (_isDistributedRoom) {
      _showError(
        'Visibility changes are not supported for decentralized rooms',
      );
      return;
    }
    setState(() => _isLoading = true);

    try {
      // Get current channel
      final channel = _chatService.channels.firstWhere(
        (c) => c.id == widget.channel.id,
        orElse: () => widget.channel,
      );

      if (channel.config == null) {
        throw Exception('Channel config not found');
      }

      // Create updated config with new visibility
      final updatedConfig = channel.config!.copyWith(
        visibility: newVisibility,
        // When making a room restricted, set current user as owner if not set
        owner: newVisibility == 'RESTRICTED' && channel.config!.owner == null
            ? _userNpub
            : channel.config!.owner,
        // Add current user to members if making restricted
        members:
            newVisibility == 'RESTRICTED' &&
                !channel.config!.members.contains(_userNpub)
            ? [...channel.config!.members, _userNpub!]
            : channel.config!.members,
      );

      // Update the channel
      await _chatService.updateChannel(channel.copyWith(config: updatedConfig));

      _showSuccess(
        newVisibility == 'RESTRICTED'
            ? _i18n.t('room_made_restricted')
            : _i18n.t('room_made_public'),
      );
      await _loadData();
    } catch (e) {
      _showError('Failed to change visibility: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
    }
  }
}

/// Internal class to hold member information
class _MemberInfo {
  final String npub;
  final String role;
  final String callsign;
  final String? nickname;

  _MemberInfo({
    required this.npub,
    required this.role,
    required this.callsign,
    this.nickname,
  });

  /// Get display name: "Nickname (CALLSIGN)" or just "CALLSIGN"
  String get displayName {
    if (nickname != null && nickname!.isNotEmpty) {
      return '$nickname ($callsign)';
    }
    return callsign;
  }
}
