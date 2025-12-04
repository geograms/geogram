/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/group.dart';
import '../models/group_member.dart';
import '../models/group_area.dart';
import '../models/group_application.dart';
import '../services/groups_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import 'location_picker_page.dart';

/// Group detail page with tabs for managing all aspects
class GroupDetailPage extends StatefulWidget {
  final String collectionPath;
  final String groupName;

  const GroupDetailPage({
    super.key,
    required this.collectionPath,
    required this.groupName,
  });

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> with SingleTickerProviderStateMixin {
  final GroupsService _groupsService = GroupsService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();

  late TabController _tabController;
  Group? _group;
  List<GroupApplication> _applications = [];
  bool _isLoading = true;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _groupsService.initializeCollection(widget.collectionPath);
    await _loadGroup();
  }

  Future<void> _loadGroup() async {
    setState(() => _isLoading = true);

    final group = await _groupsService.loadGroup(widget.groupName);
    final applications = await _groupsService.loadApplications(widget.groupName);

    final currentProfile = _profileService.getProfile();
    final isAdmin = group?.isAdmin(currentProfile.npub) ?? false;

    setState(() {
      _group = group;
      _applications = applications;
      _isAdmin = isAdmin;
      _isLoading = false;
    });
  }

  Future<void> _addMember() async {
    if (_group == null) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _AddMemberDialog(),
    );

    if (result != null) {
      final now = DateTime.now();
      final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

      final member = GroupMember(
        callsign: result['callsign'],
        npub: result['npub'],
        role: result['role'],
        joined: timestamp,
      );

      await _groupsService.addMember(widget.groupName, member);
      await _loadGroup();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('member_added'))),
        );
      }
    }
  }

  Future<void> _removeMember(GroupMember member) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('confirm')),
        content: Text(_i18n.t('remove_member_confirm').replaceAll('{member}', member.callsign)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('remove')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _groupsService.removeMember(widget.groupName, member.npub);
      await _loadGroup();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('member_removed'))),
        );
      }
    }
  }

  Future<void> _changeRole(GroupMember member) async {
    final result = await showDialog<GroupRole>(
      context: context,
      builder: (context) => _ChangeRoleDialog(currentRole: member.role),
    );

    if (result != null && result != member.role) {
      await _groupsService.updateMemberRole(widget.groupName, member.npub, result);
      await _loadGroup();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('role_updated'))),
        );
      }
    }
  }

  Future<void> _addArea() async {
    final result = await showDialog<GroupArea>(
      context: context,
      builder: (context) => _AddAreaDialog(),
    );

    if (result != null && _group != null) {
      final updatedAreas = [..._group!.areas, result];
      await _groupsService.saveAreas(widget.groupName, updatedAreas);
      await _loadGroup();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('area_added'))),
        );
      }
    }
  }

  Future<void> _removeArea(GroupArea area) async {
    if (_group == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('confirm')),
        content: Text(_i18n.t('remove_area_confirm').replaceAll('{area}', area.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('remove')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final updatedAreas = _group!.areas.where((a) => a.id != area.id).toList();
      await _groupsService.saveAreas(widget.groupName, updatedAreas);
      await _loadGroup();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('area_removed'))),
        );
      }
    }
  }

  Future<void> _openInNavigator(double latitude, double longitude) async {
    Uri mapUri;
    if (!kIsWeb && Platform.isAndroid) {
      // Android: canLaunchUrl often returns false for geo: URIs even when they work
      mapUri = Uri.parse('geo:$latitude,$longitude?q=$latitude,$longitude');
      await launchUrl(mapUri);
    } else if (!kIsWeb && Platform.isIOS) {
      // iOS: Use Apple Maps
      mapUri = Uri.parse('https://maps.apple.com/?q=$latitude,$longitude');
      await launchUrl(mapUri);
    } else {
      // Desktop/Web: Use OpenStreetMap
      mapUri = Uri.parse('https://www.openstreetmap.org/?mlat=$latitude&mlon=$longitude&zoom=15');
      if (await canLaunchUrl(mapUri)) {
        await launchUrl(mapUri);
      }
    }
  }

  Future<void> _reviewApplication(GroupApplication application, bool approve) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _ReviewApplicationDialog(
        application: application,
        approve: approve,
      ),
    );

    if (result != null) {
      final now = DateTime.now();
      final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';
      final currentProfile = _profileService.getProfile();

      final updatedApplication = application.copyWith(
        status: approve ? ApplicationStatus.approved : ApplicationStatus.rejected,
        decision: approve ? 'approved' : 'rejected',
        decidedBy: currentProfile.callsign,
        decidedByNpub: currentProfile.npub,
        decidedAt: timestamp,
        approvedRole: approve ? result['role'] : null,
        decisionReason: result['reason'],
      );

      await _groupsService.moveApplication(
        widget.groupName,
        updatedApplication,
        approve ? ApplicationStatus.approved : ApplicationStatus.rejected,
      );

      // If approved, add member to group
      if (approve) {
        final member = GroupMember(
          callsign: application.applicant,
          npub: application.npub,
          role: result['role'],
          joined: timestamp,
        );
        await _groupsService.addMember(widget.groupName, member);
      }

      await _loadGroup();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(approve ? _i18n.t('application_approved') : _i18n.t('application_rejected'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(_i18n.t('loading'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_group!.title),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: _i18n.t('overview')),
            Tab(text: _i18n.t('members')),
            Tab(text: _i18n.t('applications')),
            Tab(text: _i18n.t('areas')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildOverviewTab(),
          _buildMembersTab(),
          _buildApplicationsTab(),
          _buildAreasTab(),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _i18n.t('description'),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(_group!.description),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _InfoChip(Icons.category, _i18n.t('type'), _group!.type.name),
                    _InfoChip(Icons.people, _i18n.t('members'), '${_group!.memberCount}'),
                    _InfoChip(Icons.location_on, _i18n.t('areas'), '${_group!.areaCount}'),
                    _InfoChip(Icons.calendar_today, _i18n.t('created'), _group!.created.split(' ')[0]),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMembersTab() {
    return Column(
      children: [
        if (_isAdmin)
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: _addMember,
              icon: const Icon(Icons.person_add),
              label: Text(_i18n.t('add_member')),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _group!.members.length,
            itemBuilder: (context, index) {
              final member = _group!.members[index];
              return ListTile(
                leading: CircleAvatar(
                  child: Text(member.callsign[0].toUpperCase()),
                ),
                title: Text(member.callsign),
                subtitle: Text(member.npub),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RoleBadge(member.role),
                    if (_isAdmin) ...[
                      const SizedBox(width: 8),
                      PopupMenuButton(
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            onTap: () => _changeRole(member),
                            child: Text(_i18n.t('change_role')),
                          ),
                          PopupMenuItem(
                            onTap: () => _removeMember(member),
                            child: Text(_i18n.t('remove')),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildApplicationsTab() {
    final pendingApps = _applications.where((a) => a.isPending).toList();

    if (pendingApps.isEmpty) {
      return Center(
        child: Text(_i18n.t('no_pending_applications')),
      );
    }

    return ListView.builder(
      itemCount: pendingApps.length,
      itemBuilder: (context, index) {
        final app = pendingApps[index];
        return Card(
          margin: const EdgeInsets.all(8),
          child: ExpansionTile(
            title: Text(app.applicant),
            subtitle: Text('${_i18n.t('requested_role')}: ${app.requestedRole.name}'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (app.experience != null) ...[
                      Text(_i18n.t('experience'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(app.experience!),
                      const SizedBox(height: 8),
                    ],
                    Text(_i18n.t('introduction'), style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(app.introduction),
                    if (app.references.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(_i18n.t('references'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ...app.references.map((ref) => Text('• $ref')),
                    ],
                    if (_isAdmin) ...[
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _reviewApplication(app, false),
                            child: Text(_i18n.t('reject')),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => _reviewApplication(app, true),
                            child: Text(_i18n.t('approve')),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAreasTab() {
    return Column(
      children: [
        if (_isAdmin)
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: _addArea,
              icon: const Icon(Icons.add_location),
              label: Text(_i18n.t('add_area')),
            ),
          ),
        Expanded(
          child: _group!.areas.isEmpty
              ? Center(child: Text(_i18n.t('no_areas')))
              : ListView.builder(
                  itemCount: _group!.areas.length,
                  itemBuilder: (context, index) {
                    final area = _group!.areas[index];
                    return ListTile(
                      leading: const Icon(Icons.location_on),
                      title: Text(area.name),
                      subtitle: Text('${area.latitude}, ${area.longitude} (${area.radiusKm} km)'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.navigation, size: 20),
                            onPressed: () => _openInNavigator(area.latitude, area.longitude),
                            tooltip: _i18n.t('open_in_navigator'),
                          ),
                          if (_isAdmin)
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () => _removeArea(area),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text('$label: $value'),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final GroupRole role;

  const _RoleBadge(this.role);

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (role) {
      case GroupRole.admin:
        color = Colors.red;
        break;
      case GroupRole.moderator:
        color = Colors.orange;
        break;
      case GroupRole.contributor:
        color = Colors.blue;
        break;
      case GroupRole.guest:
        color = Colors.grey;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        role.name.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

// Dialogs implementations will be added next...
class _AddMemberDialog extends StatefulWidget {
  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  final I18nService _i18n = I18nService();
  final _callsignController = TextEditingController();
  final _npubController = TextEditingController();
  GroupRole _selectedRole = GroupRole.contributor;

  @override
  void dispose() {
    _callsignController.dispose();
    _npubController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('add_member')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _callsignController,
            decoration: InputDecoration(labelText: _i18n.t('callsign')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _npubController,
            decoration: InputDecoration(labelText: 'Npub'),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<GroupRole>(
            value: _selectedRole,
            decoration: InputDecoration(labelText: _i18n.t('role')),
            items: GroupRole.values.map((role) => DropdownMenuItem(
              value: role,
              child: Text(role.name),
            )).toList(),
            onChanged: (value) {
              if (value != null) setState(() => _selectedRole = value);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        ElevatedButton(
          onPressed: () {
            if (_callsignController.text.isNotEmpty && _npubController.text.isNotEmpty) {
              Navigator.pop(context, {
                'callsign': _callsignController.text,
                'npub': _npubController.text,
                'role': _selectedRole,
              });
            }
          },
          child: Text(_i18n.t('add')),
        ),
      ],
    );
  }
}

class _ChangeRoleDialog extends StatefulWidget {
  final GroupRole currentRole;

  const _ChangeRoleDialog({required this.currentRole});

  @override
  State<_ChangeRoleDialog> createState() => _ChangeRoleDialogState();
}

class _ChangeRoleDialogState extends State<_ChangeRoleDialog> {
  final I18nService _i18n = I18nService();
  late GroupRole _selectedRole;

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.currentRole;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('change_role')),
      content: DropdownButtonFormField<GroupRole>(
        value: _selectedRole,
        decoration: InputDecoration(labelText: _i18n.t('role')),
        items: GroupRole.values.map((role) => DropdownMenuItem(
          value: role,
          child: Text(role.name),
        )).toList(),
        onChanged: (value) {
          if (value != null) setState(() => _selectedRole = value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _selectedRole),
          child: Text(_i18n.t('save')),
        ),
      ],
    );
  }
}

class _AddAreaDialog extends StatefulWidget {
  @override
  State<_AddAreaDialog> createState() => _AddAreaDialogState();
}

class _AddAreaDialogState extends State<_AddAreaDialog> {
  final I18nService _i18n = I18nService();
  final _nameController = TextEditingController();
  final _latController = TextEditingController();
  final _lonController = TextEditingController();
  final _radiusController = TextEditingController(text: '5.0');
  String _inputMethod = 'map'; // 'map' or 'manual'
  LatLng? _selectedLocation;

  @override
  void dispose() {
    _nameController.dispose();
    _latController.dispose();
    _lonController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  Future<void> _openMapPicker() async {
    final result = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: _selectedLocation,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _selectedLocation = result;
        _latController.text = result.latitude.toStringAsFixed(6);
        _lonController.text = result.longitude.toStringAsFixed(6);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('add_area')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(labelText: _i18n.t('area_name')),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _inputMethod,
              decoration: InputDecoration(labelText: _i18n.t('input_method')),
              items: [
                DropdownMenuItem(value: 'map', child: Text(_i18n.t('pick_on_map'))),
                DropdownMenuItem(value: 'manual', child: Text(_i18n.t('enter_manually'))),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _inputMethod = value);
              },
            ),
            const SizedBox(height: 16),
            if (_inputMethod == 'map') ...[
              ElevatedButton.icon(
                onPressed: _openMapPicker,
                icon: const Icon(Icons.map),
                label: Text(_selectedLocation == null
                    ? _i18n.t('select_location')
                    : _i18n.t('change_location')),
              ),
              if (_selectedLocation != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${_selectedLocation!.latitude.toStringAsFixed(6)}, ${_selectedLocation!.longitude.toStringAsFixed(6)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ] else ...[
              TextField(
                controller: _latController,
                decoration: InputDecoration(labelText: _i18n.t('latitude')),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _lonController,
                decoration: InputDecoration(labelText: _i18n.t('longitude')),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _radiusController,
              decoration: InputDecoration(labelText: _i18n.t('radius_km')),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        ElevatedButton(
          onPressed: () {
            final lat = double.tryParse(_latController.text);
            final lon = double.tryParse(_lonController.text);
            final radius = double.tryParse(_radiusController.text);

            if (_nameController.text.isNotEmpty && lat != null && lon != null && radius != null) {
              final area = GroupArea(
                id: 'area_${DateTime.now().millisecondsSinceEpoch}',
                name: _nameController.text,
                latitude: lat,
                longitude: lon,
                radiusKm: radius,
                priority: 'medium', // Default value since priority is still in the model
              );
              Navigator.pop(context, area);
            }
          },
          child: Text(_i18n.t('add')),
        ),
      ],
    );
  }
}

class _ReviewApplicationDialog extends StatefulWidget {
  final GroupApplication application;
  final bool approve;

  const _ReviewApplicationDialog({
    required this.application,
    required this.approve,
  });

  @override
  State<_ReviewApplicationDialog> createState() => _ReviewApplicationDialogState();
}

class _ReviewApplicationDialogState extends State<_ReviewApplicationDialog> {
  final I18nService _i18n = I18nService();
  final _reasonController = TextEditingController();
  late GroupRole _selectedRole;

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.application.requestedRole;
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.approve ? _i18n.t('approve_application') : _i18n.t('reject_application')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.approve)
            DropdownButtonFormField<GroupRole>(
              value: _selectedRole,
              decoration: InputDecoration(labelText: _i18n.t('approved_role')),
              items: GroupRole.values.map((role) => DropdownMenuItem(
                value: role,
                child: Text(role.name),
              )).toList(),
              onChanged: (value) {
                if (value != null) setState(() => _selectedRole = value);
              },
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _reasonController,
            decoration: InputDecoration(
              labelText: _i18n.t('decision_reason'),
              hintText: _i18n.t('explain_decision'),
            ),
            maxLines: 3,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        ElevatedButton(
          onPressed: () {
            if (_reasonController.text.isNotEmpty) {
              Navigator.pop(context, {
                'role': widget.approve ? _selectedRole : null,
                'reason': _reasonController.text,
              });
            }
          },
          child: Text(widget.approve ? _i18n.t('approve') : _i18n.t('reject')),
        ),
      ],
    );
  }
}
