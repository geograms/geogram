/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../services/relay_node_service.dart';
import '../models/relay_node.dart';

/// Authority role types
enum AuthorityRole {
  admin,
  groupAdmin,
  moderator,
}

/// An authority entry
class AuthorityEntry {
  final String callsign;
  final String npub;
  final AuthorityRole role;
  final String? collectionType; // For group admins and moderators
  final DateTime appointed;
  final String appointedBy;
  final String status;
  final String? scope;

  AuthorityEntry({
    required this.callsign,
    required this.npub,
    required this.role,
    this.collectionType,
    required this.appointed,
    required this.appointedBy,
    this.status = 'active',
    this.scope,
  });

  factory AuthorityEntry.fromFile(String filePath, AuthorityRole role, String? collectionType) {
    final file = File(filePath);
    final content = file.readAsStringSync();
    final lines = content.split('\n');

    String? callsign;
    String? npub;
    DateTime? appointed;
    String? appointedBy;
    String? status;
    String? scope;

    for (final line in lines) {
      if (line.startsWith('CALLSIGN:')) {
        callsign = line.substring('CALLSIGN:'.length).trim();
      } else if (line.startsWith('NPUB:')) {
        npub = line.substring('NPUB:'.length).trim();
      } else if (line.startsWith('APPOINTED:')) {
        final dateStr = line.substring('APPOINTED:'.length).trim();
        try {
          appointed = DateTime.parse(dateStr.replaceAll('_', ':').replaceFirst(' ', 'T'));
        } catch (_) {
          appointed = DateTime.now();
        }
      } else if (line.startsWith('APPOINTED_BY:')) {
        appointedBy = line.substring('APPOINTED_BY:'.length).trim();
      } else if (line.startsWith('STATUS:')) {
        status = line.substring('STATUS:'.length).trim();
      } else if (line.startsWith('SCOPE:') || line.startsWith('REGIONS:')) {
        scope = line.substring(line.indexOf(':') + 1).trim();
      }
    }

    return AuthorityEntry(
      callsign: callsign ?? path.basenameWithoutExtension(filePath),
      npub: npub ?? '',
      role: role,
      collectionType: collectionType,
      appointed: appointed ?? DateTime.now(),
      appointedBy: appointedBy ?? 'unknown',
      status: status ?? 'active',
      scope: scope,
    );
  }
}

/// Page for managing relay authorities (admins, group admins, moderators)
class RelayAuthoritiesPage extends StatefulWidget {
  const RelayAuthoritiesPage({super.key});

  @override
  State<RelayAuthoritiesPage> createState() => _RelayAuthoritiesPageState();
}

class _RelayAuthoritiesPageState extends State<RelayAuthoritiesPage> with SingleTickerProviderStateMixin {
  final RelayNodeService _relayNodeService = RelayNodeService();

  late TabController _tabController;
  List<AuthorityEntry> _admins = [];
  List<AuthorityEntry> _groupAdmins = [];
  List<AuthorityEntry> _moderators = [];
  bool _isLoading = true;
  String? _error;
  String? _rootCallsign;
  String? _rootNpub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadAuthorities();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAuthorities() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final relayDir = await _relayNodeService.getRelayDirectory();
      final authDir = Directory(path.join(relayDir.path, 'authorities'));

      if (!await authDir.exists()) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      // Load root
      final rootFile = File(path.join(authDir.path, 'root.txt'));
      if (await rootFile.exists()) {
        final content = await rootFile.readAsString();
        for (final line in content.split('\n')) {
          if (line.startsWith('CALLSIGN:')) {
            _rootCallsign = line.substring('CALLSIGN:'.length).trim();
          } else if (line.startsWith('NPUB:')) {
            _rootNpub = line.substring('NPUB:'.length).trim();
          }
        }
      }

      // Load admins
      _admins = await _loadAuthorityDir(
        path.join(authDir.path, 'admins'),
        AuthorityRole.admin,
        null,
      );

      // Load group admins
      final groupAdminsDir = Directory(path.join(authDir.path, 'group-admins'));
      _groupAdmins = [];
      if (await groupAdminsDir.exists()) {
        for (final collectionDir in groupAdminsDir.listSync()) {
          if (collectionDir is Directory) {
            final collectionType = path.basename(collectionDir.path);
            final entries = await _loadAuthorityDir(
              collectionDir.path,
              AuthorityRole.groupAdmin,
              collectionType,
            );
            _groupAdmins.addAll(entries);
          }
        }
      }

      // Load moderators
      final moderatorsDir = Directory(path.join(authDir.path, 'moderators'));
      _moderators = [];
      if (await moderatorsDir.exists()) {
        for (final collectionDir in moderatorsDir.listSync()) {
          if (collectionDir is Directory) {
            final collectionType = path.basename(collectionDir.path);
            final entries = await _loadAuthorityDir(
              collectionDir.path,
              AuthorityRole.moderator,
              collectionType,
            );
            _moderators.addAll(entries);
          }
        }
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<List<AuthorityEntry>> _loadAuthorityDir(String dirPath, AuthorityRole role, String? collectionType) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];

    final entries = <AuthorityEntry>[];
    for (final file in dir.listSync()) {
      if (file is File && file.path.endsWith('.txt')) {
        try {
          entries.add(AuthorityEntry.fromFile(file.path, role, collectionType));
        } catch (_) {
          // Skip malformed files
        }
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final node = _relayNodeService.relayNode;
    final isRoot = node?.isRoot ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text('Network Authorities'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadAuthorities,
            tooltip: 'Refresh',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Admins', icon: Icon(Icons.admin_panel_settings)),
            Tab(text: 'Group Admins', icon: Icon(Icons.group)),
            Tab(text: 'Moderators', icon: Icon(Icons.shield)),
          ],
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : Column(
                  children: [
                    _buildRootCard(),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildAuthorityList(_admins, AuthorityRole.admin, isRoot),
                          _buildAuthorityList(_groupAdmins, AuthorityRole.groupAdmin, isRoot),
                          _buildAuthorityList(_moderators, AuthorityRole.moderator, isRoot),
                        ],
                      ),
                    ),
                  ],
                ),
      floatingActionButton: isRoot
          ? FloatingActionButton(
              onPressed: _showAddAuthorityDialog,
              tooltip: 'Add authority',
              child: Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildRootCard() {
    return Card(
      margin: EdgeInsets.all(8),
      color: Colors.amber.withOpacity(0.1),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.hub, color: Colors.amber[700]),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Root Authority', style: TextStyle(fontWeight: FontWeight.bold)),
                  if (_rootCallsign != null) Text('Callsign: $_rootCallsign', style: TextStyle(fontSize: 12)),
                  if (_rootNpub != null) Text('NPUB: ${_truncateNpub(_rootNpub!)}', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _truncateNpub(String npub) {
    if (npub.length > 20) {
      return '${npub.substring(0, 10)}...${npub.substring(npub.length - 8)}';
    }
    return npub;
  }

  Widget _buildAuthorityList(List<AuthorityEntry> authorities, AuthorityRole role, bool isRoot) {
    if (authorities.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_getRoleIcon(role), size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('No ${_getRoleName(role)}s yet', style: TextStyle(color: Colors.grey)),
            if (isRoot) ...[
              SizedBox(height: 8),
              Text('Tap + to add one', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(8),
      itemCount: authorities.length,
      itemBuilder: (context, index) {
        final entry = authorities[index];
        return _buildAuthorityCard(entry, isRoot);
      },
    );
  }

  Widget _buildAuthorityCard(AuthorityEntry entry, bool isRoot) {
    final statusColor = entry.status == 'active' ? Colors.green : Colors.grey;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
          child: Icon(_getRoleIcon(entry.role), color: Colors.white),
        ),
        title: Text(entry.callsign),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.collectionType != null)
              Text('Collection: ${entry.collectionType}', style: TextStyle(fontSize: 12)),
            if (entry.scope != null)
              Text('Scope: ${entry.scope}', style: TextStyle(fontSize: 12)),
            Text('NPUB: ${_truncateNpub(entry.npub)}', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            if (isRoot)
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert),
                onSelected: (action) => _handleAuthorityAction(action, entry),
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'view', child: Text('View details')),
                  PopupMenuItem(value: 'revoke', child: Text('Revoke', style: TextStyle(color: Colors.red))),
                ],
              ),
          ],
        ),
        onTap: () => _showAuthorityDetail(entry),
      ),
    );
  }

  IconData _getRoleIcon(AuthorityRole role) {
    switch (role) {
      case AuthorityRole.admin:
        return Icons.admin_panel_settings;
      case AuthorityRole.groupAdmin:
        return Icons.group;
      case AuthorityRole.moderator:
        return Icons.shield;
    }
  }

  String _getRoleName(AuthorityRole role) {
    switch (role) {
      case AuthorityRole.admin:
        return 'Admin';
      case AuthorityRole.groupAdmin:
        return 'Group Admin';
      case AuthorityRole.moderator:
        return 'Moderator';
    }
  }

  void _showAuthorityDetail(AuthorityEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(_getRoleIcon(entry.role)),
            SizedBox(width: 8),
            Text(entry.callsign),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDetailRow('Role', _getRoleName(entry.role)),
            if (entry.collectionType != null) _buildDetailRow('Collection', entry.collectionType!),
            _buildDetailRow('NPUB', entry.npub),
            _buildDetailRow('Appointed', _formatDate(entry.appointed)),
            _buildDetailRow('Appointed by', entry.appointedBy),
            _buildDetailRow('Status', entry.status),
            if (entry.scope != null) _buildDetailRow('Scope', entry.scope!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Expanded(
            child: SelectableText(value, style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _handleAuthorityAction(String action, AuthorityEntry entry) {
    if (action == 'view') {
      _showAuthorityDetail(entry);
    } else if (action == 'revoke') {
      _confirmRevoke(entry);
    }
  }

  void _confirmRevoke(AuthorityEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke Authority?'),
        content: Text(
          'Are you sure you want to revoke ${entry.callsign}\'s ${_getRoleName(entry.role)} role?\n\n'
          'This will remove their authority immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _revokeAuthority(entry);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Revoke'),
          ),
        ],
      ),
    );
  }

  Future<void> _revokeAuthority(AuthorityEntry entry) async {
    try {
      final relayDir = await _relayNodeService.getRelayDirectory();
      String filePath;

      switch (entry.role) {
        case AuthorityRole.admin:
          filePath = path.join(relayDir.path, 'authorities', 'admins', '${entry.callsign}.txt');
          break;
        case AuthorityRole.groupAdmin:
          filePath = path.join(relayDir.path, 'authorities', 'group-admins', entry.collectionType!, '${entry.callsign}.txt');
          break;
        case AuthorityRole.moderator:
          filePath = path.join(relayDir.path, 'authorities', 'moderators', entry.collectionType!, '${entry.callsign}.txt');
          break;
      }

      final file = File(filePath);
      if (await file.exists()) {
        // Move to revoked folder (or delete)
        await file.delete();
      }

      await _loadAuthorities();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Authority revoked: ${entry.callsign}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _showAddAuthorityDialog() {
    showDialog(
      context: context,
      builder: (context) => _AddAuthorityDialog(
        onAdd: (entry) async {
          await _addAuthority(entry);
        },
      ),
    );
  }

  Future<void> _addAuthority(AuthorityEntry entry) async {
    try {
      final relayDir = await _relayNodeService.getRelayDirectory();
      String dirPath;

      switch (entry.role) {
        case AuthorityRole.admin:
          dirPath = path.join(relayDir.path, 'authorities', 'admins');
          break;
        case AuthorityRole.groupAdmin:
          dirPath = path.join(relayDir.path, 'authorities', 'group-admins', entry.collectionType!);
          break;
        case AuthorityRole.moderator:
          dirPath = path.join(relayDir.path, 'authorities', 'moderators', entry.collectionType!);
          break;
      }

      await Directory(dirPath).create(recursive: true);

      final file = File(path.join(dirPath, '${entry.callsign}.txt'));
      final roleLabel = entry.role == AuthorityRole.admin
          ? 'ADMIN'
          : entry.role == AuthorityRole.groupAdmin
              ? 'GROUP ADMIN'
              : 'MODERATOR';

      await file.writeAsString('''
# $roleLabel: ${entry.callsign}
${entry.collectionType != null ? '# COLLECTION: ${entry.collectionType}\n' : ''}
CALLSIGN: ${entry.callsign}
NPUB: ${entry.npub}
APPOINTED: ${_formatDateForFile(entry.appointed)}
APPOINTED_BY: ${entry.appointedBy}
${entry.scope != null ? 'SCOPE: ${entry.scope}\n' : ''}STATUS: active
''');

      await _loadAuthorities();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Authority added: ${entry.callsign}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateForFile(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}_${date.minute.toString().padLeft(2, '0')}_${date.second.toString().padLeft(2, '0')}';
  }
}

/// Dialog for adding a new authority
class _AddAuthorityDialog extends StatefulWidget {
  final Function(AuthorityEntry) onAdd;

  const _AddAuthorityDialog({required this.onAdd});

  @override
  State<_AddAuthorityDialog> createState() => _AddAuthorityDialogState();
}

class _AddAuthorityDialogState extends State<_AddAuthorityDialog> {
  final _callsignController = TextEditingController();
  final _npubController = TextEditingController();
  final _scopeController = TextEditingController();

  AuthorityRole _role = AuthorityRole.admin;
  String? _collectionType;

  final _collectionTypes = ['reports', 'places', 'events', 'forum', 'chat', 'shops', 'services'];

  @override
  void dispose() {
    _callsignController.dispose();
    _npubController.dispose();
    _scopeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add Authority'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Role', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            SegmentedButton<AuthorityRole>(
              segments: [
                ButtonSegment(value: AuthorityRole.admin, label: Text('Admin')),
                ButtonSegment(value: AuthorityRole.groupAdmin, label: Text('Group')),
                ButtonSegment(value: AuthorityRole.moderator, label: Text('Mod')),
              ],
              selected: {_role},
              onSelectionChanged: (value) {
                setState(() {
                  _role = value.first;
                  if (_role == AuthorityRole.admin) {
                    _collectionType = null;
                  }
                });
              },
            ),
            if (_role != AuthorityRole.admin) ...[
              SizedBox(height: 16),
              Text('Collection Type', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _collectionType,
                decoration: InputDecoration(border: OutlineInputBorder()),
                hint: Text('Select collection'),
                items: _collectionTypes.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (value) => setState(() => _collectionType = value),
              ),
            ],
            SizedBox(height: 16),
            TextField(
              controller: _callsignController,
              decoration: InputDecoration(
                labelText: 'Callsign *',
                hintText: 'e.g., CR7BBQ',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _npubController,
              decoration: InputDecoration(
                labelText: 'NPUB *',
                hintText: 'npub1...',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _scopeController,
              decoration: InputDecoration(
                labelText: 'Scope (optional)',
                hintText: 'e.g., Lisbon region',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text('Add'),
        ),
      ],
    );
  }

  void _submit() {
    if (_callsignController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Callsign is required')),
      );
      return;
    }

    if (_npubController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('NPUB is required')),
      );
      return;
    }

    if (_role != AuthorityRole.admin && _collectionType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Collection type is required for this role')),
      );
      return;
    }

    final node = RelayNodeService().relayNode;

    final entry = AuthorityEntry(
      callsign: _callsignController.text.trim().toUpperCase(),
      npub: _npubController.text.trim(),
      role: _role,
      collectionType: _collectionType,
      appointed: DateTime.now(),
      appointedBy: node?.npub ?? 'unknown',
      scope: _scopeController.text.isNotEmpty ? _scopeController.text.trim() : null,
    );

    Navigator.pop(context);
    widget.onAdd(entry);
  }
}
