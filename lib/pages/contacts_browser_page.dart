/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/contact.dart';
import '../services/contact_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import 'add_edit_contact_page.dart';

/// Contacts browser page with 2-panel layout
class ContactsBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;

  const ContactsBrowserPage({
    Key? key,
    required this.collectionPath,
    required this.collectionTitle,
  }) : super(key: key);

  @override
  State<ContactsBrowserPage> createState() => _ContactsBrowserPageState();
}

class _ContactsBrowserPageState extends State<ContactsBrowserPage> {
  final ContactService _contactService = ContactService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<Contact> _allContacts = [];
  List<Contact> _filteredContacts = [];
  List<ContactGroup> _groups = [];
  Contact? _selectedContact;
  String? _selectedGroupPath;
  bool _isLoading = true;
  String _viewMode = 'all'; // all, group, revoked
  Set<String> _expandedGroups = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterContacts);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Initialize contact service
    await _contactService.initializeCollection(widget.collectionPath);
    await _loadContacts();
    await _loadGroups();
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);

    final contacts = await _contactService.loadAllContactsRecursively();

    setState(() {
      _allContacts = contacts;
      _filteredContacts = contacts;
      _isLoading = false;
    });

    _filterContacts();

    // Auto-select first contact
    if (_allContacts.isNotEmpty && _selectedContact == null) {
      setState(() => _selectedContact = _allContacts.first);
    }
  }

  Future<void> _loadGroups() async {
    final groups = await _contactService.loadGroups();
    setState(() {
      _groups = groups;
    });
  }

  void _filterContacts() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      var filtered = _allContacts;

      // Apply view mode filter
      if (_viewMode == 'group' && _selectedGroupPath != null) {
        filtered = filtered.where((c) => c.groupPath == _selectedGroupPath).toList();
      } else if (_viewMode == 'revoked') {
        filtered = filtered.where((c) => c.revoked).toList();
      }

      // Apply search filter
      if (query.isNotEmpty) {
        filtered = filtered.where((contact) {
          return contact.displayName.toLowerCase().contains(query) ||
                 contact.callsign.toLowerCase().contains(query) ||
                 contact.npub.toLowerCase().contains(query) ||
                 contact.notes.toLowerCase().contains(query) ||
                 contact.emails.any((e) => e.toLowerCase().contains(query)) ||
                 contact.phones.any((p) => p.toLowerCase().contains(query));
        }).toList();
      }

      _filteredContacts = filtered;
    });
  }

  void _selectContact(Contact contact) {
    setState(() {
      _selectedContact = contact;
    });
  }

  Future<void> _selectContactMobile(Contact contact) async {
    if (!mounted) return;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => _ContactDetailPage(
          contact: contact,
          contactService: _contactService,
          profileService: _profileService,
          i18n: _i18n,
          collectionPath: widget.collectionPath,
        ),
      ),
    );

    // Reload contacts if changes were made
    if (result == true && mounted) {
      await _loadContacts();
      await _loadGroups();
    }
  }

  void _selectGroup(String? groupPath) {
    setState(() {
      _selectedGroupPath = groupPath;
      _viewMode = groupPath == null ? 'all' : 'group';
    });
    _filterContacts();
  }

  void _toggleGroup(String groupPath) {
    setState(() {
      if (_expandedGroups.contains(groupPath)) {
        _expandedGroups.remove(groupPath);
      } else {
        _expandedGroups.add(groupPath);
      }
    });
  }

  Future<void> _createNewContact() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditContactPage(
          collectionPath: widget.collectionPath,
        ),
      ),
    );

    if (result == true) {
      await _loadContacts();
    }
  }

  Future<void> _editContact(Contact contact) async {
    // TODO: Show edit contact dialog
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Edit ${contact.displayName} - TODO')),
    );
  }

  Future<void> _deleteContact(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_contact')),
        content: Text(_i18n.t('delete_contact_confirm', params: [contact.displayName])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _contactService.deleteContact(
        contact.callsign,
        groupPath: contact.groupPath != null && contact.groupPath!.isNotEmpty ? contact.groupPath : null,
      );

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('contact_deleted', params: [contact.displayName]))),
        );
        await _loadContacts();
      }
    }
  }

  Future<void> _createNewGroup() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('create_group')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: _i18n.t('group_name'),
                hintText: _i18n.t('group_name_hint'),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                labelText: _i18n.t('description_optional'),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty) {
      final profile = _profileService.getProfile();
      final success = await _contactService.createGroup(
        nameController.text,
        description: descController.text.isNotEmpty ? descController.text : null,
        author: profile.callsign,
      );

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('group_created', params: [nameController.text]))),
        );
        await _loadGroups();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('contacts')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createNewContact,
            tooltip: _i18n.t('new_contact'),
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            onPressed: _createNewGroup,
            tooltip: _i18n.t('new_group'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _loadContacts();
              await _loadGroups();
            },
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Use two-panel layout for wide screens, single panel for narrow
          final isWideScreen = constraints.maxWidth >= 600;

          if (isWideScreen) {
            // Desktop/landscape: Two-panel layout
            return Row(
              children: [
                // Left panel: Contact list
                Expanded(
                  flex: 1,
                  child: _buildContactList(context),
                ),
                const VerticalDivider(width: 1),
                // Right panel: Contact detail
                Expanded(
                  flex: 2,
                  child: _selectedContact == null
                      ? Center(
                          child: Text(_i18n.t('select_contact_to_view')),
                        )
                      : _buildContactDetail(_selectedContact!),
                ),
              ],
            );
          } else {
            // Mobile/portrait: Single panel
            return _buildContactList(context, isMobileView: true);
          }
        },
      ),
    );
  }

  Widget _buildContactList(BuildContext context, {bool isMobileView = false}) {
    return Column(
              children: [
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: _i18n.t('search_contacts'),
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                    ),
                  ),
                ),

                // View mode selector
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text('${_i18n.t('all')} (${_allContacts.length})'),
                        selected: _viewMode == 'all',
                        onSelected: (_) => _selectGroup(null),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text('${_i18n.t('revoked')} (${_allContacts.where((c) => c.revoked).length})'),
                        selected: _viewMode == 'revoked',
                        onSelected: (_) {
                          setState(() => _viewMode = 'revoked');
                          _filterContacts();
                        },
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                // Groups list
                if (_groups.isNotEmpty) ...[
                  ExpansionTile(
                    title: Text(_i18n.t('groups')),
                    initiallyExpanded: true,
                    children: _groups.map((group) {
                      return ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(group.name),
                        subtitle: Text('${group.contactCount} ${_i18n.t('contacts').toLowerCase()}'),
                        selected: _selectedGroupPath == group.path,
                        onTap: () => _selectGroup(group.path),
                      );
                    }).toList(),
                  ),
                  const Divider(height: 1),
                ],

                // Contact list
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredContacts.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.contacts, size: 64, color: Colors.grey),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchController.text.isNotEmpty
                                        ? _i18n.t('no_contacts_found')
                                        : _i18n.t('no_contacts_yet'),
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          color: Colors.grey,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    icon: const Icon(Icons.add),
                                    label: Text(_i18n.t('create_contact')),
                                    onPressed: _createNewContact,
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: _filteredContacts.length,
                              itemBuilder: (context, index) {
                                final contact = _filteredContacts[index];
                                return _buildContactListTile(contact, isMobileView: isMobileView);
                              },
                            ),
                ),
              ],
            );
  }

  Widget _buildContactListTile(Contact contact, {bool isMobileView = false}) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: contact.revoked ? Colors.red : Colors.blue,
        child: Text(
          contact.callsign.substring(0, 2),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(contact.displayName)),
          if (contact.revoked)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _i18n.t('revoked').toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          if (contact.isProbablyMachine)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.computer, size: 16, color: Colors.grey),
            ),
        ],
      ),
      subtitle: Text(contact.callsign),
      selected: _selectedContact?.callsign == contact.callsign,
      onTap: () => isMobileView ? _selectContactMobile(contact) : _selectContact(contact),
      trailing: PopupMenuButton(
        itemBuilder: (context) => [
          PopupMenuItem(value: 'edit', child: Text(_i18n.t('edit'))),
          PopupMenuItem(value: 'delete', child: Text(_i18n.t('delete'))),
        ],
        onSelected: (value) {
          if (value == 'edit') _editContact(contact);
          if (value == 'delete') _deleteContact(contact);
        },
      ),
    );
  }

  Widget _buildContactDetail(Contact contact) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: contact.revoked ? Colors.red : Colors.blue,
                child: Text(
                  contact.callsign.substring(0, 2),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          contact.displayName,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        if (contact.isProbablyMachine) ...[
                          const SizedBox(width: 8),
                          Chip(
                            label: Text(_i18n.t('machine'), style: const TextStyle(fontSize: 12)),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      contact.callsign,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (contact.groupPath != null && contact.groupPath!.isNotEmpty)
                      Text(
                        '${_i18n.t('group')}: ${contact.groupDisplayName}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Revoked warning
          if (contact.revoked) ...[
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning, color: Colors.red.shade700),
                        const SizedBox(width: 8),
                        Text(
                          _i18n.t('revoked_identity').toUpperCase(),
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    if (contact.revocationReason != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        contact.revocationReason!,
                        style: TextStyle(color: Colors.red.shade900),
                      ),
                    ],
                    if (contact.successor != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${_i18n.t('successor')}: ${contact.successor}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (contact.successorSince != null)
                        Text('${_i18n.t('since')}: ${contact.displaySuccessorSince}'),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Previous identity info
          if (contact.previousIdentity != null) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.history),
                title: Text(_i18n.t('previous_identity')),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(contact.previousIdentity!),
                    if (contact.previousIdentitySince != null)
                      Text('${_i18n.t('changed')}: ${contact.displayPreviousIdentitySince}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // NPUB
          _buildInfoSection(_i18n.t('nostr_identity'), [
            _buildInfoRow('npub', contact.npub, monospace: true),
          ]),

          // Contact Information
          if (contact.emails.isNotEmpty ||
              contact.phones.isNotEmpty ||
              contact.addresses.isNotEmpty ||
              contact.websites.isNotEmpty)
            _buildInfoSection(_i18n.t('contact_information'), [
              ...contact.emails.map((e) => _buildInfoRow(_i18n.t('email'), e)),
              ...contact.phones.map((p) => _buildInfoRow(_i18n.t('phone'), p)),
              ...contact.addresses.map((a) => _buildInfoRow(_i18n.t('address'), a)),
              ...contact.websites.map((w) => _buildInfoRow(_i18n.t('website'), w)),
            ]),

          // Locations (for postcard delivery)
          if (contact.locations.isNotEmpty)
            _buildInfoSection(_i18n.t('typical_locations'), [
              ...contact.locations.map((loc) => _buildInfoRow(
                    loc.name,
                    loc.latitude != null && loc.longitude != null
                        ? '${loc.latitude}, ${loc.longitude}'
                        : '',
                  )),
            ]),

          // Timestamps
          _buildInfoSection(_i18n.t('metadata'), [
            _buildInfoRow(_i18n.t('first_seen'), contact.displayFirstSeen),
            _buildInfoRow(_i18n.t('file_created'), contact.displayCreated),
            if (contact.filePath != null)
              _buildInfoRow(_i18n.t('file_path'), contact.filePath!, monospace: true),
          ]),

          // Notes
          if (contact.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _i18n.t('notes'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(contact.notes),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Actions
          Row(
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.edit),
                label: Text(_i18n.t('edit')),
                onPressed: () => _editContact(contact),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete),
                label: Text(_i18n.t('delete')),
                onPressed: () => _deleteContact(contact),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {bool monospace = false}) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen contact detail page for mobile view
class _ContactDetailPage extends StatelessWidget {
  final Contact contact;
  final ContactService contactService;
  final ProfileService profileService;
  final I18nService i18n;
  final String collectionPath;

  const _ContactDetailPage({
    Key? key,
    required this.contact,
    required this.contactService,
    required this.profileService,
    required this.i18n,
    required this.collectionPath,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(contact.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final result = await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AddEditContactPage(
                    collectionPath: collectionPath,
                    contact: contact,
                  ),
                ),
              );
              if (result == true && context.mounted) {
                Navigator.pop(context, true);
              }
            },
          ),
        ],
      ),
      body: _buildContactDetail(context),
    );
  }

  Widget _buildContactDetail(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: contact.revoked ? Colors.red : Colors.blue,
                child: Text(
                  contact.callsign.substring(0, 2),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            contact.displayName,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                        if (contact.isProbablyMachine) ...[
                          const SizedBox(width: 8),
                          Chip(
                            label: Text(i18n.t('machine'), style: const TextStyle(fontSize: 12)),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      contact.callsign,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (contact.groupPath != null && contact.groupPath!.isNotEmpty)
                      Text(
                        '${i18n.t('group')}: ${contact.groupDisplayName}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),

          if (contact.revoked) ...[
            const SizedBox(height: 16),
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.block, color: Colors.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        i18n.t('contact_revoked_warning'),
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          // Details
          _buildDetailRow(i18n.t('npub'), contact.npub, monospace: true),
          _buildDetailRow(i18n.t('callsign'), contact.callsign),

          // Contact Information
          if (contact.emails.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              i18n.t('emails'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            ...contact.emails.map((e) => _buildDetailRow(i18n.t('email'), e)),
          ],

          if (contact.phones.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              i18n.t('phones'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            ...contact.phones.map((p) => _buildDetailRow(i18n.t('phone'), p)),
          ],

          if (contact.websites.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              i18n.t('websites'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            ...contact.websites.map((w) => _buildDetailRow(i18n.t('website'), w)),
          ],

          // Notes
          if (contact.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              i18n.t('notes'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(contact.notes),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool monospace = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
