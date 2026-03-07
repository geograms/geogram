/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../util/navigator_launcher.dart';
import '../dialogs/place_picker_dialog.dart';
import '../models/contact.dart';
// Re-export history entry types
export '../models/contact.dart' show ContactHistoryEntry, ContactHistoryEntryType;
import '../platform/file_image_helper.dart' as file_helper;
import '../services/app_service.dart';
import '../services/contact_service.dart';
// Re-export metrics and summary classes from contact_service
export '../services/contact_service.dart' show ContactCallsignMetrics, ContactMetrics, ContactSummary;
import '../services/event_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/i18n_service.dart';
import '../models/event.dart';
import '../widgets/transcribe_button_widget.dart';
import 'add_edit_contact_page.dart';
import 'contact_import_page.dart';
import 'contact_qr_scan_page.dart';
import 'contact_qr_page.dart';
import 'contact_tools_page.dart';
import 'contact_merge_page.dart';
import 'location_picker_page.dart';

/// Get initials from display name (e.g., "John Smith" -> "JS")
String _getContactInitials(String displayName) {
  final words = displayName.trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words[0].isEmpty) return '?';
  if (words.length == 1) {
    // Single word: use first two characters
    return words[0].substring(0, words[0].length >= 2 ? 2 : 1).toUpperCase();
  }
  // Multiple words: use first character of first two words
  return '${words[0][0]}${words[1][0]}'.toUpperCase();
}

/// Contacts browser page with 2-panel layout
class ContactsBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;

  const ContactsBrowserPage({
    Key? key,
    required this.appPath,
    required this.appTitle,
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
  List<Contact> _topContacts = [];
  Contact? _selectedContact;
  String? _selectedGroupPath;
  bool _isLoading = true;
  String _viewMode = 'all'; // all, group, revoked
  Set<String> _expandedGroups = {};

  // Multi-select state
  bool _isSelectionMode = false;
  Set<String> _selectedCallsigns = {};

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
    // Set profile storage for encrypted storage support
    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      _contactService.setStorage(scopedStorage);
    } else {
      _contactService.setStorage(FilesystemProfileStorage(widget.appPath));
    }

    // Initialize contact service
    await _contactService.initializeApp(widget.appPath);
    await _loadContacts();
    await _loadGroups();
    await _loadTopContacts();
  }

  Future<void> _loadTopContacts() async {
    final topContacts = await _contactService.getTopContacts(30);
    setState(() {
      _topContacts = topContacts;
    });
  }

  // Multi-select methods
  void _enterSelectionMode([String? initialCallsign]) {
    setState(() {
      _isSelectionMode = true;
      _selectedCallsigns.clear();
      if (initialCallsign != null) {
        _selectedCallsigns.add(initialCallsign);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedCallsigns.clear();
    });
  }

  void _toggleContactSelection(String callsign) {
    setState(() {
      if (_selectedCallsigns.contains(callsign)) {
        _selectedCallsigns.remove(callsign);
        // Exit selection mode if no contacts selected
        if (_selectedCallsigns.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedCallsigns.add(callsign);
      }
    });
  }

  void _selectAllContacts() {
    setState(() {
      _selectedCallsigns = _filteredContacts.map((c) => c.callsign).toSet();
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedCallsigns.clear();
    });
  }

  bool _isContactSelected(String callsign) {
    return _selectedCallsigns.contains(callsign);
  }

  List<Contact> _getSelectedContacts() {
    return _allContacts
        .where((c) => _selectedCallsigns.contains(c.callsign))
        .toList();
  }

  // Selection action methods
  Future<void> _deleteSelectedContacts() async {
    final count = _selectedCallsigns.length;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_selected')),
        content: Text(_i18n.t('delete_x_contacts_confirm').replaceAll('{count}', count.toString())),
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

    if (confirmed != true || !mounted) return;

    // Delete each selected contact
    for (final callsign in _selectedCallsigns.toList()) {
      final contact = _allContacts.firstWhere(
        (c) => c.callsign == callsign,
        orElse: () => Contact(displayName: '', callsign: callsign, created: '', firstSeen: ''),
      );
      if (contact.filePath != null) {
        await _contactService.deleteContact(contact.filePath!);
      }
    }

    _exitSelectionMode();
    await _loadContacts();
    await _loadGroups();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('x_contacts_deleted').replaceAll('{count}', count.toString())),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _moveSelectedContacts() async {
    final count = _selectedCallsigns.length;
    if (count == 0) return;

    // Show folder picker dialog
    final targetGroup = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('select_destination_folder')),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Root (no folder)
              ListTile(
                leading: const Icon(Icons.home),
                title: Text(_i18n.t('root_folder')),
                onTap: () => Navigator.pop(context, ''),
              ),
              const Divider(),
              // Existing groups
              ..._groups.map((group) => ListTile(
                leading: const Icon(Icons.folder, color: Colors.amber),
                title: Text(_getTranslatedGroupName(group)),
                onTap: () => Navigator.pop(context, group.path),
              )),
              const Divider(),
              // Create new folder
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: Text(_i18n.t('create_new_folder')),
                onTap: () async {
                  Navigator.pop(context);
                  final newPath = await _createNewGroupAndGetPath();
                  if (newPath != null && mounted) {
                    _moveContactsToGroup(newPath);
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );

    if (targetGroup == null || !mounted) return;

    await _moveContactsToGroup(targetGroup);
  }

  Future<void> _moveContactsToGroup(String targetGroupPath) async {
    final count = _selectedCallsigns.length;

    for (final callsign in _selectedCallsigns.toList()) {
      final contact = _allContacts.firstWhere(
        (c) => c.callsign == callsign,
        orElse: () => Contact(displayName: '', callsign: callsign, created: '', firstSeen: ''),
      );
      if (contact.filePath != null) {
        await _contactService.moveContactToGroup(contact.callsign, targetGroupPath.isEmpty ? null : targetGroupPath);
      }
    }

    _exitSelectionMode();
    await _loadContacts();
    await _loadGroups();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('x_contacts_moved').replaceAll('{count}', count.toString())),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<String?> _createNewGroupAndGetPath() async {
    final nameController = TextEditingController();

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('create_group')),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: _i18n.t('folder_name'),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return null;

    final success = await _contactService.createGroup(name);
    if (!success) return null;

    await _loadGroups();
    return name;
  }

  Future<void> _mergeSelectedContacts() async {
    final selectedContacts = _getSelectedContacts();
    if (selectedContacts.length < 2) return;

    // Navigate to merge page with selected contacts
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => ContactMergePage(
          contactService: _contactService,
          i18n: _i18n,
          contactsToMerge: selectedContacts,
        ),
      ),
    );

    if (result == true && mounted) {
      _exitSelectionMode();
      await _loadContacts();
    }
  }

  void _openContactTools() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContactToolsPage(
          contactService: _contactService,
          i18n: _i18n,
          appPath: widget.appPath,
          onDeleteAll: _deleteAllContactsAndGroups,
          onRefresh: _loadContacts,
        ),
      ),
    );
  }

  Future<void> _loadContacts() async {
    setState(() {
      _isLoading = true;
      _allContacts = [];
      _filteredContacts = [];
    });

    // Use fast streaming loader for instant display
    // First loads from fast.json (instant), then populates full details in background
    await for (final contact in _contactService.loadAllContactsStreamFast()) {
      if (!mounted) return;

      setState(() {
        _allContacts.add(contact);
      });

      // Auto-select first contact as soon as it arrives
      if (_allContacts.length == 1 && _selectedContact == null) {
        setState(() => _selectedContact = contact);
      }

      // Update filtered list periodically (every 10 contacts or when small)
      if (_allContacts.length <= 10 || _allContacts.length % 10 == 0) {
        _filterContacts();
      }
    }

    // Final filter pass after all contacts loaded
    setState(() => _isLoading = false);
    _filterContacts();
  }

  Future<void> _loadGroups() async {
    final groups = await _contactService.loadGroups();
    setState(() {
      _groups = groups;
    });
  }

  /// Get groups that are direct children of the current level
  List<ContactGroup> _getGroupsAtCurrentLevel() {
    if (_viewMode == 'all') {
      // At root level, show groups without '/' in their path (root-level groups)
      return _groups.where((g) => !g.path.contains('/')).toList();
    } else if (_viewMode == 'group' && _selectedGroupPath != null) {
      // Inside a group, show direct subgroups
      final prefix = '$_selectedGroupPath/';
      return _groups.where((g) {
        if (!g.path.startsWith(prefix)) return false;
        // Check it's a direct child (no additional '/' after the prefix)
        final remainder = g.path.substring(prefix.length);
        return !remainder.contains('/');
      }).toList();
    }
    return [];
  }

  void _filterContacts() {
    final query = _searchController.text.toLowerCase();

    var filtered = _allContacts;

    // Check for special search syntax: "event:EVENTID"
    if (query.startsWith('event:')) {
      final eventId = query.substring(6).trim();
      if (eventId.isNotEmpty) {
        // Filter contacts that have history entries with this event reference
        // Search across ALL contacts (ignore folder navigation for event search)
        filtered = _allContacts.where((contact) {
          return contact.historyEntries.any((entry) =>
              entry.eventReference?.toLowerCase() == eventId ||
              entry.eventReference?.toLowerCase().contains(eventId) == true);
        }).toList();
        _sortAndSetFilteredContacts(filtered);
        return;
      }
    }

    // Apply view mode filter - folder-style navigation
    if (_viewMode == 'group' && _selectedGroupPath != null) {
      // Inside a specific group folder - show only contacts in this group
      filtered = filtered.where((c) => c.groupPath == _selectedGroupPath).toList();
    } else if (_viewMode == 'revoked') {
      filtered = filtered.where((c) => c.revoked).toList();
    } else if (_viewMode == 'all') {
      // Root level - show only contacts without a group (folder-style)
      filtered = filtered.where((c) => c.groupPath == null || c.groupPath!.isEmpty).toList();
    }

    // Apply search filter
    if (query.isNotEmpty) {
      filtered = filtered.where((contact) {
        return contact.displayName.toLowerCase().contains(query) ||
               contact.callsign.toLowerCase().contains(query) ||
               (contact.npub?.toLowerCase().contains(query) ?? false) ||
               contact.notes.toLowerCase().contains(query) ||
               contact.emails.any((e) => e.toLowerCase().contains(query)) ||
               contact.phones.any((p) => p.toLowerCase().contains(query));
      }).toList();
    }

    // Sort by popularity (async, will update state when done)
    _sortAndSetFilteredContacts(filtered);
  }

  Future<void> _sortAndSetFilteredContacts(List<Contact> contacts) async {
    // Sort by popularity
    final sorted = await _contactService.sortContactsByPopularity(contacts);

    if (mounted) {
      setState(() {
        _filteredContacts = sorted;
      });
    }
  }

  void _selectContact(Contact contact) async {
    // Check if this is a placeholder contact (from fast.json)
    // Placeholders have no npub set and no created timestamp from file
    final isPlaceholder = contact.npub == null && contact.emails.isEmpty && contact.phones.isEmpty;

    if (isPlaceholder && contact.filePath != null) {
      // Load full contact details from disk
      final fullContact = await _contactService.loadContactFromFile(contact.filePath!);
      if (fullContact != null && mounted) {
        // Update the contact in the list
        final index = _allContacts.indexWhere((c) => c.callsign == contact.callsign);
        if (index >= 0) {
          _allContacts[index] = fullContact;
        }
        setState(() {
          _selectedContact = fullContact;
        });
        _contactService.recordContactView(fullContact.callsign);
        return;
      }
    }

    setState(() {
      _selectedContact = contact;
    });
    // Record contact view for metrics
    _contactService.recordContactView(contact.callsign);
  }

  Future<void> _selectContactMobile(Contact contact) async {
    if (!mounted) return;

    // Check if this is a placeholder contact (from fast.json)
    final isPlaceholder = contact.npub == null && contact.emails.isEmpty && contact.phones.isEmpty;
    Contact contactToShow = contact;

    if (isPlaceholder && contact.filePath != null) {
      // Load full contact details from disk
      final fullContact = await _contactService.loadContactFromFile(contact.filePath!);
      if (fullContact != null) {
        // Update the contact in the list
        final index = _allContacts.indexWhere((c) => c.callsign == contact.callsign);
        if (index >= 0) {
          _allContacts[index] = fullContact;
        }
        contactToShow = fullContact;
        _contactService.recordContactView(fullContact.callsign);
      }
    } else {
      _contactService.recordContactView(contact.callsign);
    }

    if (!mounted) return;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (context) => ContactDetailPage(
          contact: contactToShow,
          contactService: _contactService,
          profileService: _profileService,
          i18n: _i18n,
          appPath: widget.appPath,
          onEventSearch: (eventId) {
            // Pop back and set the search query
            Navigator.pop(context, {'eventSearch': eventId});
          },
        ),
      ),
    );

    // Handle result - could be bool for refresh or map for event search
    if (result is Map && result['eventSearch'] != null) {
      // Set the search query to filter by event
      _searchController.text = 'event:${result['eventSearch']}';
      _filterContacts();
    } else if (result == true && mounted) {
      // Reload contacts if changes were made
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

  /// Get translated group name if a translation key exists for the group path.
  /// For example, "imported_contacts" becomes "Imported Contacts" in English.
  String _getTranslatedGroupName(ContactGroup group) {
    // Try to translate the group path as a key (e.g., "imported_contacts")
    return _i18n.tOrDefault(group.path, group.name);
  }

  /// Get translated group name from path string
  String _getTranslatedGroupNameFromPath(String path) {
    final group = _groups.firstWhere(
      (g) => g.path == path,
      orElse: () => ContactGroup(name: path, path: path, contactCount: 0),
    );
    return _getTranslatedGroupName(group);
  }

  Future<void> _createNewContact() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditContactPage(
          appPath: widget.appPath,
          groupPath: _viewMode == 'group' ? _selectedGroupPath : null,
        ),
      ),
    );

    if (result == true) {
      await _loadContacts();
    }
  }

  Future<void> _editContact(Contact contact) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditContactPage(
          appPath: widget.appPath,
          contact: contact,
        ),
      ),
    );

    if (result == true) {
      await _loadContacts();
      await _loadGroups();
    }
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
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                labelText: _i18n.t('description_optional'),
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
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
      // If we're inside a group, create the new group as a subgroup
      final groupPath = _selectedGroupPath != null && _selectedGroupPath!.isNotEmpty
          ? '$_selectedGroupPath/${nameController.text}'
          : nameController.text;

      final success = await _contactService.createGroup(
        groupPath,
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

  Future<void> _importFromDevice() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContactImportPage(
          appPath: widget.appPath,
          groupPath: _viewMode == 'group' ? _selectedGroupPath : null,
        ),
      ),
    );

    if (result == true) {
      await _loadContacts();
      await _loadGroups();
    }
  }

  Future<void> _openQrCode() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContactQrPage(
          contactService: _contactService,
          i18n: _i18n,
          initialContact: _selectedContact,
        ),
      ),
    );

    if (result == true) {
      await _loadContacts();
    }
  }

  Widget _buildEmptyStateWithQuickAccess(bool isMobileView) {
    // Show top contacts when no root contacts exist but contacts are in folders
    if (_topContacts.isEmpty) {
      // No popular contacts yet - guide the user
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.star_outline,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 16),
              Text(
                _i18n.t('no_popular_contacts'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Quick Access header
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.star, size: 24, color: Colors.amber.shade600),
              const SizedBox(width: 8),
              Text(
                _i18n.t('quick_access'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
        // Top contacts grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              childAspectRatio: 0.70,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _topContacts.length,
            itemBuilder: (context, index) => _buildQuickAccessCard(_topContacts[index], isMobileView),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickAccessCard(Contact contact, bool isMobileView) {
    final profilePicturePath = _contactService.getProfilePicturePath(contact.callsign);
    final hasProfilePicture = !kIsWeb && profilePicturePath != null && file_helper.fileExists(profilePicturePath);
    final profileImage = hasProfilePicture ? file_helper.getFileImageProvider(profilePicturePath) : null;

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () => isMobileView
            ? _selectContactMobile(contact)
            : _selectContact(contact),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: contact.revoked ? Colors.red : Colors.blue,
                backgroundImage: profileImage,
                child: profileImage == null
                    ? Text(
                        _getContactInitials(contact.displayName),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Text(
                  contact.displayName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameGroup(ContactGroup group) async {
    final nameController = TextEditingController(text: group.name);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('rename_folder')),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: _i18n.t('folder_name'),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: Text(_i18n.t('rename')),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != group.name) {
      final success = await _contactService.renameGroup(group.path, newName);

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('folder_renamed'))),
        );
        await _loadGroups();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('folder_rename_failed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteGroup(ContactGroup group) async {
    if (group.contactCount > 0) {
      // Group has contacts - show confirmation to delete with contacts
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.warning, color: Colors.orange),
              const SizedBox(width: 12),
              Expanded(child: Text(_i18n.t('delete_folder_with_contacts'))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_i18n.t('delete_folder_with_contacts_confirm', params: [
                _getTranslatedGroupName(group),
                group.contactCount.toString(),
              ])),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withAlpha(50)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.delete_forever, color: Colors.red, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${group.contactCount} ${_i18n.t('contacts').toLowerCase()}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
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
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(_i18n.t('delete')),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        final success = await _contactService.deleteGroupWithContacts(group.path);

        if (success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('folder_with_contacts_deleted'))),
          );
          await _loadContacts();
          await _loadGroups();
        }
      }
      return;
    }

    // Empty group - simple confirmation
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_folder')),
        content: Text(_i18n.t('delete_folder_confirm', params: [_getTranslatedGroupName(group)])),
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
      final success = await _contactService.deleteGroup(group.path);

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('folder_deleted'))),
        );
        await _loadGroups();
      }
    }
  }

  Future<void> _deleteAllContactsAndGroups() async {
    // Get counts for the warning message
    final contactCount = await _contactService.getTotalContactCount();
    final groupCount = await _contactService.getTotalGroupCount();

    if (contactCount == 0 && groupCount == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('no_contacts'))),
        );
      }
      return;
    }

    // First confirmation with warning
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning, color: Colors.red),
            const SizedBox(width: 12),
            Expanded(child: Text(_i18n.t('delete_all_contacts_title'))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_i18n.t('delete_all_contacts_warning', params: [
              contactCount.toString(),
              groupCount.toString(),
            ])),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withAlpha(50)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person, color: Colors.red, size: 20),
                      const SizedBox(width: 12),
                      Text('$contactCount ${_i18n.t('contacts').toLowerCase()}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.folder, color: Colors.red, size: 20),
                      const SizedBox(width: 12),
                      Text('$groupCount ${_i18n.t('groups').toLowerCase()}'),
                    ],
                  ),
                ],
              ),
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
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(_i18n.t('continue')),
          ),
        ],
      ),
    );

    if (firstConfirm != true || !mounted) return;

    // Second confirmation - require typing DELETE
    final confirmController = TextEditingController();
    final secondConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.delete_forever, color: Colors.red),
              const SizedBox(width: 12),
              Expanded(child: Text(_i18n.t('delete_all_contacts_title'))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_i18n.t('delete_all_contacts_confirm')),
              const SizedBox(height: 16),
              TextField(
                controller: confirmController,
                autofocus: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'DELETE',
                  hintStyle: TextStyle(color: Colors.grey.withAlpha(100)),
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_i18n.t('cancel')),
            ),
            TextButton(
              onPressed: confirmController.text.toUpperCase() == 'DELETE'
                  ? () => Navigator.pop(context, true)
                  : null,
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(_i18n.t('delete')),
            ),
          ],
        ),
      ),
    );

    if (secondConfirm != true || !mounted) return;

    // Perform the deletion
    final success = await _contactService.deleteAllContactsAndGroups();

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('delete_all_contacts_success')),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        _allContacts = [];
        _filteredContacts = [];
        _selectedContact = null;
      });
      await _loadGroups();
    }
  }

  AppBar _buildNormalAppBar() {
    // Show folder name in title when inside a folder
    final title = _viewMode == 'group' && _selectedGroupPath != null
        ? _getTranslatedGroupNameFromPath(_selectedGroupPath!)
        : _viewMode == 'revoked'
            ? _i18n.t('revoked')
            : _i18n.t('contacts');

    return AppBar(
      // Show back button when inside a folder
      leading: _viewMode == 'group' && _selectedGroupPath != null
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => _selectGroup(null),
              tooltip: _i18n.t('back'),
            )
          : null,
      title: Text(title),
      actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: _i18n.t('menu'),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'new_contact',
              child: Row(
                children: [
                  const Icon(Icons.person_add),
                  const SizedBox(width: 12),
                  Text(_i18n.t('new_contact')),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'create_group',
              child: Row(
                children: [
                  const Icon(Icons.create_new_folder),
                  const SizedBox(width: 12),
                  Text(_i18n.t('create_group')),
                ],
              ),
            ),
            if (!kIsWeb && Platform.isAndroid)
              PopupMenuItem(
                value: 'import_contacts',
                child: Row(
                  children: [
                    const Icon(Icons.contact_phone),
                    const SizedBox(width: 12),
                    Text(_i18n.t('import_from_device')),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'qr_code',
              child: Row(
                children: [
                  const Icon(Icons.qr_code),
                  const SizedBox(width: 12),
                  Text(_i18n.t('qr_code')),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'tools',
              child: Row(
                children: [
                  const Icon(Icons.build),
                  const SizedBox(width: 12),
                  Text(_i18n.t('contact_tools')),
                ],
              ),
            ),
          ],
          onSelected: (value) {
            if (value == 'new_contact') {
              _createNewContact();
            } else if (value == 'create_group') {
              _createNewGroup();
            } else if (value == 'import_contacts') {
              _importFromDevice();
            } else if (value == 'qr_code') {
              _openQrCode();
            } else if (value == 'tools') {
              _openContactTools();
            }
          },
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar() {
    final count = _selectedCallsigns.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectionMode,
        tooltip: _i18n.t('cancel'),
      ),
      title: Text(_i18n.t('x_selected').replaceAll('{count}', count.toString())),
      actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'select_all':
                _selectAllContacts();
                break;
              case 'move':
                if (count > 0) _moveSelectedContacts();
                break;
              case 'merge':
                if (count >= 2) _mergeSelectedContacts();
                break;
              case 'delete':
                if (count > 0) _deleteSelectedContacts();
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'select_all',
              child: Row(
                children: [
                  const Icon(Icons.select_all),
                  const SizedBox(width: 12),
                  Text(_i18n.t('select_all')),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'move',
              enabled: count > 0,
              child: Row(
                children: [
                  const Icon(Icons.drive_file_move),
                  const SizedBox(width: 12),
                  Text(_i18n.t('move_selected')),
                ],
              ),
            ),
            if (count >= 2)
              PopupMenuItem<String>(
                value: 'merge',
                child: Row(
                  children: [
                    const Icon(Icons.merge),
                    const SizedBox(width: 12),
                    Text(_i18n.t('merge_selected')),
                  ],
                ),
              ),
            PopupMenuItem<String>(
              value: 'delete',
              enabled: count > 0,
              child: Row(
                children: [
                  const Icon(Icons.delete),
                  const SizedBox(width: 12),
                  Text(_i18n.t('delete_selected')),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Handle back navigation - go up one level in folder hierarchy
  void _navigateBack() {
    if (_selectedGroupPath != null && _selectedGroupPath!.isNotEmpty) {
      // Check if we're in a nested group (has /)
      final lastSlash = _selectedGroupPath!.lastIndexOf('/');
      if (lastSlash > 0) {
        // Go up one level
        _selectGroup(_selectedGroupPath!.substring(0, lastSlash));
      } else {
        // At top level of a group, go back to all contacts
        _selectGroup(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Intercept back button when inside a group folder
    final canPop = _viewMode != 'group' || _selectedGroupPath == null;

    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !canPop) {
          _navigateBack();
        }
      },
      child: Scaffold(
        appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
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

                // Revoked filter chip (only show if there are revoked contacts)
                if (_allContacts.any((c) => c.revoked))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                    child: FilterChip(
                      label: Text(_i18n.t('revoked')),
                      selected: _viewMode == 'revoked',
                      onSelected: (_) {
                        if (_viewMode == 'revoked') {
                          _selectGroup(null);
                        } else {
                          setState(() => _viewMode = 'revoked');
                          _filterContacts();
                        }
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                  ),

                const Divider(height: 1),

                // Groups as folder items - show at current level
                if (_groups.isNotEmpty && _viewMode != 'revoked' && _searchController.text.isEmpty)
                  for (final group in _getGroupsAtCurrentLevel()) ListTile(
                    leading: const Icon(Icons.folder, color: Colors.amber),
                    title: Text(_getTranslatedGroupName(group)),
                    subtitle: Text('${group.contactCount} ${_i18n.t('contacts').toLowerCase()}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PopupMenuButton(
                          icon: const Icon(Icons.more_vert, size: 20),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'rename',
                              child: Row(
                                children: [
                                  const Icon(Icons.edit, size: 20),
                                  const SizedBox(width: 8),
                                  Text(_i18n.t('rename')),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  const Icon(Icons.delete, size: 20, color: Colors.red),
                                  const SizedBox(width: 8),
                                  Text(_i18n.t('delete'), style: const TextStyle(color: Colors.red)),
                                ],
                              ),
                            ),
                          ],
                          onSelected: (value) {
                            if (value == 'rename') _renameGroup(group);
                            if (value == 'delete') _deleteGroup(group);
                          },
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => _selectGroup(group.path),
                  ),

                if (_getGroupsAtCurrentLevel().isNotEmpty && _searchController.text.isEmpty)
                  const Divider(height: 1),

                // Contact list
                Expanded(
                  child: _isLoading
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(
                                '${_i18n.t('loading')}... ${_allContacts.length}',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Colors.grey,
                                    ),
                              ),
                            ],
                          ),
                        )
                      : _filteredContacts.isEmpty
                          // Only show "no contacts" if there are truly no contacts anywhere
                          ? (_allContacts.isEmpty && _groups.isEmpty)
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
                                      // Show import option on Android only
                                      if (!kIsWeb && Platform.isAndroid)
                                        TextButton.icon(
                                          icon: const Icon(Icons.import_contacts),
                                          label: Text(_i18n.t('import_from_device')),
                                          onPressed: _importFromDevice,
                                        ),
                                    ],
                                  ),
                                )
                              // Groups exist but no root contacts - show Quick Access with top contacts
                              : _searchController.text.isNotEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(32),
                                        child: Text(
                                          _i18n.t('no_contacts_found'),
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: Colors.grey,
                                              ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    )
                                  : _buildEmptyStateWithQuickAccess(isMobileView)
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
    final profilePicturePath = _contactService.getProfilePicturePath(contact.callsign);
    final hasProfilePicture = !kIsWeb && profilePicturePath != null && file_helper.fileExists(profilePicturePath);
    final profileImage = hasProfilePicture ? file_helper.getFileImageProvider(profilePicturePath) : null;
    final isSelected = _isContactSelected(contact.callsign);

    // Build avatar widget
    Widget avatar = CircleAvatar(
      backgroundColor: contact.revoked ? Colors.red : Colors.blue,
      backgroundImage: profileImage,
      child: profileImage == null
          ? Text(
              _getContactInitials(contact.displayName),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            )
          : null,
    );

    // In selection mode, show checkbox overlay or replace avatar
    Widget leadingWidget;
    if (_isSelectionMode) {
      leadingWidget = Stack(
        children: [
          avatar,
          Positioned(
            right: -4,
            bottom: -4,
            child: Container(
              decoration: BoxDecoration(
                color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Icon(
                isSelected ? Icons.check : Icons.circle_outlined,
                size: 18,
                color: isSelected ? Colors.white : Colors.grey,
              ),
            ),
          ),
        ],
      );
    } else {
      leadingWidget = avatar;
    }

    return ListTile(
      leading: leadingWidget,
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
      subtitle: Text(contact.secondaryInfo ?? contact.callsign),
      selected: _isSelectionMode ? isSelected : _selectedContact?.callsign == contact.callsign,
      onTap: () {
        if (_isSelectionMode) {
          _toggleContactSelection(contact.callsign);
        } else if (isMobileView) {
          _selectContactMobile(contact);
        } else {
          _selectContact(contact);
        }
      },
      onLongPress: () {
        if (!_isSelectionMode) {
          _enterSelectionMode(contact.callsign);
        }
      },
      trailing: _isSelectionMode
          ? null
          : PopupMenuButton(
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
    final profilePicturePath = _contactService.getProfilePicturePath(contact.callsign);
    final hasProfilePicture = !kIsWeb && profilePicturePath != null && file_helper.fileExists(profilePicturePath);
    final profileImage = hasProfilePicture ? file_helper.getFileImageProvider(profilePicturePath) : null;

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
                backgroundImage: profileImage,
                child: profileImage == null
                    ? Text(
                        _getContactInitials(contact.displayName),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
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

          // Details (collapsible)
          ExpansionTile(
            title: Text(_i18n.t('details')),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            initiallyExpanded: false,
            children: [
              if (contact.npub != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.key, size: 14, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        'NPUB',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          contact.npub!,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        tooltip: _i18n.t('copy'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: contact.npub!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(_i18n.t('copied_to_clipboard'))),
                          );
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              _buildInfoRow(_i18n.t('callsign'), contact.callsign),
            ],
          ),

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
              ...contact.locations.map((loc) => _buildLocationRow(
                    loc.name,
                    loc.latitude,
                    loc.longitude,
                  )),
            ]),

          // Date Reminders
          if (contact.dateReminders.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _i18n.t('date_reminders'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...contact.dateReminders.map((reminder) => _buildDateReminderCard(reminder)),
          ],

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

          // History Log
          if (contact.historyEntries.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  _i18n.t('history_log'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: _i18n.t('add_history_entry'),
                  onPressed: () => _addHistoryEntry(contact),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...contact.historyEntries.map((entry) => _buildHistoryEntryCard(contact, entry)),
          ] else ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  _i18n.t('history_log'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: _i18n.t('add_history_entry'),
                  onPressed: () => _addHistoryEntry(contact),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _i18n.t('no_history_entries'),
                  style: TextStyle(color: Colors.grey[600], fontStyle: FontStyle.italic),
                ),
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

  Future<void> _openInNavigator(double latitude, double longitude) async {
    await launchExternalNavigator(latitude, longitude);
  }

  Widget _buildHistoryEntryCard(Contact contact, ContactHistoryEntry entry) {
    final typeIcon = _getHistoryTypeIcon(entry.type);
    final typeLabel = _getHistoryTypeLabel(entry.type);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(typeIcon, size: 16, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  typeLabel,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  entry.timestamp,
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                PopupMenuButton<String>(
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'edit', child: Text(_i18n.t('edit'))),
                    PopupMenuItem(value: 'delete', child: Text(_i18n.t('delete'))),
                  ],
                  onSelected: (value) {
                    if (value == 'edit') _editHistoryEntry(contact, entry);
                    if (value == 'delete') _deleteHistoryEntry(contact, entry);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(entry.content),
            if (entry.author.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '— ${entry.author}',
                style: TextStyle(color: Colors.grey[600], fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ],
            if (entry.latitude != null && entry.longitude != null) ...[
              const SizedBox(height: 4),
              InkWell(
                onTap: () => _openInNavigator(entry.latitude!, entry.longitude!),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_on, size: 14, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _getHistoryTypeIcon(ContactHistoryEntryType type) {
    switch (type) {
      case ContactHistoryEntryType.note:
        return Icons.note;
      case ContactHistoryEntryType.meeting:
        return Icons.people;
      case ContactHistoryEntryType.call:
        return Icons.phone;
      case ContactHistoryEntryType.message:
        return Icons.message;
      case ContactHistoryEntryType.location:
        return Icons.location_on;
      case ContactHistoryEntryType.event:
        return Icons.event;
      case ContactHistoryEntryType.system:
        return Icons.info;
    }
  }

  String _getHistoryTypeLabel(ContactHistoryEntryType type) {
    switch (type) {
      case ContactHistoryEntryType.note:
        return _i18n.t('note');
      case ContactHistoryEntryType.meeting:
        return _i18n.t('meeting');
      case ContactHistoryEntryType.call:
        return _i18n.t('call');
      case ContactHistoryEntryType.message:
        return _i18n.t('message');
      case ContactHistoryEntryType.location:
        return _i18n.t('location');
      case ContactHistoryEntryType.event:
        return _i18n.t('event');
      case ContactHistoryEntryType.system:
        return _i18n.t('system');
    }
  }

  Future<void> _addHistoryEntry(Contact contact) async {
    final profile = _profileService.getProfile();
    final author = profile?.callsign ?? 'Unknown';

    final contentController = TextEditingController();
    ContactHistoryEntryType selectedType = ContactHistoryEntryType.note;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(_i18n.t('add_history_entry')),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<ContactHistoryEntryType>(
                      value: selectedType,
                      decoration: InputDecoration(labelText: _i18n.t('entry_type')),
                      items: ContactHistoryEntryType.values.map((type) {
                        return DropdownMenuItem(
                          value: type,
                          child: Row(
                            children: [
                              Icon(_getHistoryTypeIcon(type), size: 18),
                              const SizedBox(width: 8),
                              Text(_getHistoryTypeLabel(type)),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setDialogState(() {
                          selectedType = value ?? ContactHistoryEntryType.note;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: contentController,
                      decoration: InputDecoration(
                        labelText: _i18n.t('content'),
                        border: const OutlineInputBorder(),
                        suffixIcon: TranscribeButtonWidget(
                          i18n: _i18n,
                          onTranscribed: (text) {
                            if (contentController.text.isEmpty) {
                              contentController.text = text;
                            } else {
                              contentController.text += ' $text';
                            }
                          },
                        ),
                      ),
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(_i18n.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(_i18n.t('add')),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && contentController.text.trim().isNotEmpty) {
      final entry = ContactHistoryEntry.now(
        author: author,
        content: contentController.text.trim(),
        type: selectedType,
      );

      final error = await _contactService.addHistoryEntry(contact.callsign, entry);
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
        }
      } else {
        await _loadContacts();
        // Re-select the contact to refresh the detail view
        final updatedContact = _allContacts.firstWhere(
          (c) => c.callsign == contact.callsign,
          orElse: () => contact,
        );
        setState(() => _selectedContact = updatedContact);
      }
    }
  }

  Future<void> _editHistoryEntry(Contact contact, ContactHistoryEntry entry) async {
    final contentController = TextEditingController(text: entry.content);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_i18n.t('edit_history_entry')),
          content: SizedBox(
            width: 400,
            child: TextField(
              controller: contentController,
              decoration: InputDecoration(
                labelText: _i18n.t('content'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_i18n.t('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_i18n.t('save')),
            ),
          ],
        );
      },
    );

    if (result == true && contentController.text.trim().isNotEmpty) {
      final error = await _contactService.editHistoryEntry(
        contact.callsign,
        entry.timestamp,
        contentController.text.trim(),
      );
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
        }
      } else {
        await _loadContacts();
        final updatedContact = _allContacts.firstWhere(
          (c) => c.callsign == contact.callsign,
          orElse: () => contact,
        );
        setState(() => _selectedContact = updatedContact);
      }
    }
  }

  Future<void> _deleteHistoryEntry(Contact contact, ContactHistoryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_history_entry')),
        content: Text(_i18n.t('delete_history_entry_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final error = await _contactService.deleteHistoryEntry(contact.callsign, entry.timestamp);
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
        }
      } else {
        await _loadContacts();
        final updatedContact = _allContacts.firstWhere(
          (c) => c.callsign == contact.callsign,
          orElse: () => contact,
        );
        setState(() => _selectedContact = updatedContact);
      }
    }
  }

  Widget _buildDateReminderCard(ContactDateReminder reminder) {
    final now = DateTime.now();
    final thisYear = now.year;

    // Calculate next occurrence
    var nextOccurrence = DateTime(thisYear, reminder.month, reminder.day);
    if (nextOccurrence.isBefore(now) || nextOccurrence.isAtSameMomentAs(now)) {
      // If the date has passed this year, use next year
      nextOccurrence = DateTime(thisYear + 1, reminder.month, reminder.day);
    }

    final daysRemaining = nextOccurrence.difference(now).inDays;

    // Choose icon based on type
    IconData icon;
    Color iconColor;
    switch (reminder.type) {
      case ContactDateReminderType.birthday:
        icon = Icons.cake;
        iconColor = Colors.pink;
        break;
      case ContactDateReminderType.deceased:
        icon = Icons.favorite;
        iconColor = Colors.grey;
        break;
      case ContactDateReminderType.married:
        icon = Icons.favorite;
        iconColor = Colors.red;
        break;
      case ContactDateReminderType.relationStart:
        icon = Icons.people;
        iconColor = Colors.green;
        break;
      case ContactDateReminderType.relationEnd:
        icon = Icons.people_outline;
        iconColor = Colors.orange;
        break;
      case ContactDateReminderType.other:
        icon = Icons.event;
        iconColor = Colors.blue;
        break;
    }

    // Format days remaining text
    String daysText;
    if (daysRemaining == 0) {
      daysText = _i18n.t('today');
    } else if (daysRemaining == 1) {
      daysText = _i18n.t('tomorrow');
    } else {
      daysText = _i18n.t('days_remaining', params: [daysRemaining.toString()]);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: iconColor.withValues(alpha: 0.15),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(reminder.displayType),
        subtitle: Text(reminder.displayDate),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: daysRemaining <= 7
                ? Colors.orange.withValues(alpha: 0.15)
                : Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            daysText,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: daysRemaining <= 7
                  ? Colors.orange.shade800
                  : Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocationRow(String label, double? latitude, double? longitude) {
    if (latitude == null || longitude == null) return const SizedBox.shrink();

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
            child: Text('$latitude, $longitude'),
          ),
          IconButton(
            icon: const Icon(Icons.navigation, size: 18),
            onPressed: () => _openInNavigator(latitude, longitude),
            tooltip: _i18n.t('open_in_navigator'),
            visualDensity: VisualDensity.compact,
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
class ContactDetailPage extends StatefulWidget {
  final Contact contact;
  final ContactService contactService;
  final ProfileService profileService;
  final I18nService i18n;
  final String appPath;
  final void Function(String eventId)? onEventSearch;

  const ContactDetailPage({
    Key? key,
    required this.contact,
    required this.contactService,
    required this.profileService,
    required this.i18n,
    required this.appPath,
    this.onEventSearch,
  }) : super(key: key);

  @override
  State<ContactDetailPage> createState() => _ContactDetailPageState();
}

class _ContactDetailPageState extends State<ContactDetailPage> {
  ContactCallsignMetrics? _metrics;
  List<_PhoneWithMetrics>? _sortedPhones;
  List<_EmailWithMetrics>? _sortedEmails;
  late Contact _contact;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
    _recordViewAndLoadMetrics();
  }

  Future<void> _recordViewAndLoadMetrics() async {
    // Record contact view
    await widget.contactService.recordContactView(widget.contact.callsign);

    // Load metrics for displaying interaction counts
    final metrics = await widget.contactService.getContactMetrics(widget.contact.callsign);

    if (mounted) {
      setState(() {
        _metrics = metrics;
        _sortedPhones = _buildSortedPhones();
        _sortedEmails = _buildSortedEmails();
      });
    }
  }

  List<_EmailWithMetrics> _buildSortedEmails() {
    final emails = <_EmailWithMetrics>[];

    for (var i = 0; i < widget.contact.emails.length; i++) {
      final email = widget.contact.emails[i];
      final count = _metrics?.getInteractionCount('email', i, value: email) ?? 0;
      emails.add(_EmailWithMetrics(email: email, index: i, interactionCount: count));
    }

    // Sort by interaction count descending
    emails.sort((a, b) => b.interactionCount.compareTo(a.interactionCount));

    return emails;
  }

  List<_PhoneWithMetrics> _buildSortedPhones() {
    final phones = <_PhoneWithMetrics>[];

    for (var i = 0; i < widget.contact.phones.length; i++) {
      final phone = widget.contact.phones[i];
      final count = _metrics?.getInteractionCount('phone', i, value: phone) ?? 0;
      phones.add(_PhoneWithMetrics(phone: phone, index: i, interactionCount: count));
    }

    // Sort by interaction count descending
    phones.sort((a, b) => b.interactionCount.compareTo(a.interactionCount));

    return phones;
  }

  Contact get contact => _contact;
  ContactService get contactService => widget.contactService;
  ProfileService get profileService => widget.profileService;
  I18nService get i18n => widget.i18n;
  String get appPath => widget.appPath;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(contact.displayName),
          actions: [
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: i18n.t('share_via_qr'),
              onPressed: () => _shareViaQr(),
            ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'edit':
                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => AddEditContactPage(
                        appPath: appPath,
                        contact: contact,
                      ),
                    ),
                  );
                  if (result == true && context.mounted) {
                    Navigator.pop(context, true);
                  }
                  break;
                case 'scan_qr':
                  _scanQrCode();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    const Icon(Icons.edit, size: 20),
                    const SizedBox(width: 12),
                    Text(i18n.t('edit')),
                  ],
                ),
              ),
              if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
                PopupMenuItem(
                  value: 'scan_qr',
                  child: Row(
                    children: [
                      const Icon(Icons.qr_code_scanner, size: 20),
                      const SizedBox(width: 12),
                      Text(i18n.t('scan_contact_qr')),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _buildContactDetail(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddInteractionMenu,
        icon: const Icon(Icons.add),
        label: Text(i18n.t('add_interaction')),
      ),
      ),
    );
  }

  void _shareViaQr() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ContactQrPage(
          contactService: contactService,
          i18n: i18n,
          initialContact: contact,
          initialTab: 0, // Send tab
        ),
      ),
    );
  }

  void _scanQrCode() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => ContactQrScanPage(
          contactService: contactService,
          i18n: i18n,
        ),
      ),
    );
    if (result == true && context.mounted) {
      // Contact was imported, pop back to refresh list
      Navigator.pop(context, true);
    }
  }

  void _showAddInteractionMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  i18n.t('add_interaction'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.note_add),
                        title: Text(i18n.t('interaction_note')),
                        onTap: () {
                          Navigator.pop(context);
                          _addHistoryEntry(ContactHistoryEntryType.note);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.phone),
                        title: Text(i18n.t('interaction_call')),
                        onTap: () {
                          Navigator.pop(context);
                          _addHistoryEntry(ContactHistoryEntryType.call);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.sms),
                        title: Text(i18n.t('interaction_message')),
                        onTap: () {
                          Navigator.pop(context);
                          _addHistoryEntry(ContactHistoryEntryType.message);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.handshake),
                        title: Text(i18n.t('interaction_meeting')),
                        onTap: () {
                          Navigator.pop(context);
                          _addHistoryEntry(ContactHistoryEntryType.meeting);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.location_on),
                        title: Text(i18n.t('interaction_location')),
                        subtitle: Text(i18n.t('select_location_on_map')),
                        onTap: () {
                          Navigator.pop(context);
                          _addLocationFromMap();
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.place_outlined),
                        title: Text(i18n.t('interaction_place')),
                        subtitle: Text(i18n.t('choose_saved_place')),
                        onTap: () {
                          Navigator.pop(context);
                          _addPlaceEntry();
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.event),
                        title: Text(i18n.t('interaction_event')),
                        subtitle: Text(i18n.t('associate_with_event')),
                        onTap: () {
                          Navigator.pop(context);
                          _addEventEntry();
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addHistoryEntry(ContactHistoryEntryType type) async {
    final noteController = TextEditingController();
    final allowTranscribe = type == ContactHistoryEntryType.note ||
        type == ContactHistoryEntryType.message ||
        type == ContactHistoryEntryType.meeting;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_getEntryTypeLabel(type)),
        content: TextField(
          controller: noteController,
          decoration: InputDecoration(
            labelText: '${i18n.t('content')} *',
            hintText: i18n.t('note_placeholder'),
            helperText: i18n.t('mandatory'),
            border: const OutlineInputBorder(),
            suffixIcon: allowTranscribe
                ? TranscribeButtonWidget(
                    i18n: i18n,
                    onTranscribed: (text) {
                      if (noteController.text.isEmpty) {
                        noteController.text = text;
                      } else {
                        noteController.text += ' $text';
                      }
                    },
                  )
                : null,
          ),
          maxLines: 4,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.t('add')),
          ),
        ],
      ),
    );

    if (confirmed != true || noteController.text.isEmpty) return;

    await _saveHistoryEntry(type, noteController.text);
  }

  /// Add a location entry by selecting coordinates on the map
  Future<void> _addLocationFromMap() async {
    // Open the map selector to pick a location
    final LatLng? selectedLocation = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (context) => const LocationPickerPage(),
      ),
    );

    if (selectedLocation == null || !mounted) return;

    // Ask for an optional note about this location
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.t('add_location_note')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show selected coordinates
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.location_on, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${selectedLocation.latitude.toStringAsFixed(5)}, ${selectedLocation.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: noteController,
              decoration: InputDecoration(
                labelText: i18n.t('note_optional'),
                hintText: i18n.t('note_placeholder'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.t('add')),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Save with coordinates
    await _saveHistoryEntryWithLocation(
      ContactHistoryEntryType.location,
      noteController.text.isEmpty ? i18n.t('location_recorded') : noteController.text,
      selectedLocation.latitude,
      selectedLocation.longitude,
    );
  }

  /// Add a place entry by selecting from saved places
  Future<void> _addPlaceEntry() async {
    // Open the place picker dialog
    final PlaceSelection? selection = await showDialog<PlaceSelection>(
      context: context,
      builder: (context) => PlacePickerDialog(i18n: i18n),
    );

    if (selection == null || !mounted) return;

    final place = selection.place;
    final langCode = i18n.currentLanguage.split('_').first.toUpperCase();
    final placeName = place.getName(langCode);

    // Ask for an optional note about this place interaction
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.t('add_place_note')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show selected place
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.place_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          placeName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (place.address?.isNotEmpty == true)
                          Text(
                            place.address!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: noteController,
              decoration: InputDecoration(
                labelText: i18n.t('note_optional'),
                hintText: i18n.t('note_placeholder'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.t('add')),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Build content with place info
    final content = noteController.text.isEmpty
        ? '${i18n.t('visited')}: $placeName'
        : '${noteController.text}\n${i18n.t('place')}: $placeName';

    // Save with place coordinates
    await _saveHistoryEntryWithLocation(
      ContactHistoryEntryType.location,
      content,
      place.latitude,
      place.longitude,
      metadata: {'place_path': place.folderPath ?? ''},
    );
  }

  /// Add an event entry by selecting from available events
  Future<void> _addEventEntry() async {
    // Load events from current collection
    final eventService = EventService();
    await eventService.initializeApp(widget.appPath);
    final events = await eventService.loadEvents();

    if (events.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(i18n.t('no_events_found'))),
        );
      }
      return;
    }

    // Sort events by date (most recent first)
    events.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Show event picker dialog
    final Event? selectedEvent = await showDialog<Event>(
      context: context,
      builder: (context) => _EventPickerDialog(events: events, i18n: i18n),
    );

    if (selectedEvent == null || !mounted) return;

    // Ask for an optional note about this event interaction
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.t('add_event_note')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show selected event
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.event, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedEvent.title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          selectedEvent.displayDate,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: noteController,
              decoration: InputDecoration(
                labelText: i18n.t('note_optional'),
                hintText: i18n.t('event_note_placeholder'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.t('add')),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Build content with event info
    final content = noteController.text.isEmpty
        ? '${i18n.t('spotted_at_event')}: ${selectedEvent.title}'
        : '${noteController.text}\n${i18n.t('event')}: ${selectedEvent.title}';

    // Save with event reference
    await _saveHistoryEntryWithEvent(
      ContactHistoryEntryType.event,
      content,
      selectedEvent.id,
    );
  }

  Future<void> _saveHistoryEntryWithEvent(
    ContactHistoryEntryType type,
    String content,
    String eventId,
  ) async {
    final profile = ProfileService().getProfile();

    final entry = ContactHistoryEntry.now(
      author: profile.callsign,
      content: content,
      type: type,
      eventReference: eventId,
    );

    // Update the contact with the new history entry
    final updatedEntries = List<ContactHistoryEntry>.from(contact.historyEntries)
      ..add(entry);

    final updatedContact = contact.copyWith(historyEntries: updatedEntries);

    // Save the contact
    final error = await contactService.saveContact(
      updatedContact,
      groupPath: contact.groupPath,
    );

    if (error == null && mounted) {
      setState(() {
        _contact = updatedContact;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(i18n.t('interaction_added')),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _saveHistoryEntry(ContactHistoryEntryType type, String content) async {
    final profile = ProfileService().getProfile();

    final entry = ContactHistoryEntry.now(
      author: profile.callsign,
      content: content,
      type: type,
    );

    // Update the contact with the new history entry
    final updatedEntries = List<ContactHistoryEntry>.from(contact.historyEntries)
      ..add(entry);

    final updatedContact = contact.copyWith(historyEntries: updatedEntries);

    // Save the contact
    final error = await contactService.saveContact(
      updatedContact,
      groupPath: contact.groupPath,
    );

    if (error == null && mounted) {
      setState(() {
        _contact = updatedContact;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(i18n.t('interaction_added')),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _saveHistoryEntryWithLocation(
    ContactHistoryEntryType type,
    String content,
    double latitude,
    double longitude, {
    Map<String, String>? metadata,
  }) async {
    final profile = ProfileService().getProfile();

    final entry = ContactHistoryEntry.now(
      author: profile.callsign,
      content: content,
      type: type,
      latitude: latitude,
      longitude: longitude,
      metadata: metadata,
    );

    // Update the contact with the new history entry
    final updatedEntries = List<ContactHistoryEntry>.from(contact.historyEntries)
      ..add(entry);

    final updatedContact = contact.copyWith(historyEntries: updatedEntries);

    // Save the contact
    final error = await contactService.saveContact(
      updatedContact,
      groupPath: contact.groupPath,
    );

    if (error == null && mounted) {
      setState(() {
        _contact = updatedContact;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(i18n.t('interaction_added')),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  String _getEntryTypeLabel(ContactHistoryEntryType type) {
    switch (type) {
      case ContactHistoryEntryType.note:
        return i18n.t('interaction_note');
      case ContactHistoryEntryType.call:
        return i18n.t('interaction_call');
      case ContactHistoryEntryType.meeting:
        return i18n.t('interaction_meeting');
      case ContactHistoryEntryType.location:
        return i18n.t('interaction_location');
      case ContactHistoryEntryType.message:
        return i18n.t('interaction_message');
      case ContactHistoryEntryType.event:
        return i18n.t('event');
      case ContactHistoryEntryType.system:
        return i18n.t('system');
    }
  }

  IconData _getEntryTypeIcon(ContactHistoryEntryType type) {
    switch (type) {
      case ContactHistoryEntryType.note:
        return Icons.note;
      case ContactHistoryEntryType.call:
        return Icons.phone;
      case ContactHistoryEntryType.meeting:
        return Icons.handshake;
      case ContactHistoryEntryType.location:
        return Icons.location_on;
      case ContactHistoryEntryType.message:
        return Icons.message;
      case ContactHistoryEntryType.event:
        return Icons.event;
      case ContactHistoryEntryType.system:
        return Icons.settings;
    }
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
                  _getContactInitials(contact.displayName),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
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

          // Details (collapsible)
          ExpansionTile(
            title: Text(i18n.t('details')),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            initiallyExpanded: false,
            children: [
              if (contact.npub != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.key, size: 14, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        'NPUB',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          contact.npub!,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        tooltip: i18n.t('copy'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: contact.npub!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(i18n.t('copied_to_clipboard'))),
                          );
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              _buildCopyableRow(context, i18n.t('callsign'), contact.callsign),
            ],
          ),

          // Contact Information - Emails
          if (contact.emails.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              i18n.t('email'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            // Use sorted emails if available, otherwise use original order
            if (_sortedEmails != null)
              ..._sortedEmails!.map((e) => _buildEmailRowWithMetrics(e))
            else
              ...contact.emails.asMap().entries.map((e) =>
                  _buildEmailRowWithMetrics(_EmailWithMetrics(
                    email: e.value,
                    index: e.key,
                    interactionCount: 0,
                  ))),
          ],

          if (contact.phones.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            // Use sorted phones if available, otherwise use original order
            if (_sortedPhones != null)
              ..._sortedPhones!.map((p) => _buildPhoneRowWithMetrics(p))
            else
              ...contact.phones.asMap().entries.map((e) =>
                  _buildPhoneRowWithMetrics(_PhoneWithMetrics(
                    phone: e.value,
                    index: e.key,
                    interactionCount: 0,
                  ))),
          ],

          if (contact.websites.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            ...contact.websites.map((w) => _buildDetailRow(i18n.t('website'), w)),
          ],

          // Date Reminders
          if (contact.dateReminders.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              i18n.t('date_reminders'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...contact.dateReminders.map((reminder) => _buildDateReminderCardMobile(reminder)),
          ],

          // Notes (static notes, not history)
          if (contact.notes.isNotEmpty && contact.historyEntries.isEmpty) ...[
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

          // Interaction History Timeline
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                i18n.t('interaction_history'),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              if (contact.historyEntries.isNotEmpty)
                Text(
                  '${contact.historyEntries.length} ${i18n.t('entries').toLowerCase()}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (contact.historyEntries.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      Icons.history,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      i18n.t('no_interactions_yet'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            )
          else
            // Timeline display (most recent first)
            ...contact.historyEntries.reversed.toList().asMap().entries.map(
              (mapEntry) => _buildHistoryEntryItem(context, mapEntry.value, mapEntry.key == contact.historyEntries.length - 1),
            ),

          // Extra space for FAB
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildHistoryEntryItem(BuildContext context, ContactHistoryEntry entry, bool isLast) {
    final theme = Theme.of(context);
    final timestamp = entry.timestamp.substring(0, 16).replaceAll('_', ':');

    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Timeline dot and line
            Column(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    _getEntryTypeIcon(entry.type),
                    size: 16,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // Entry content
            Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _getEntryTypeLabel(entry.type),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      timestamp,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${i18n.t('by')}: ${entry.author}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (entry.content.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.content,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                if (entry.hasLocation) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.location_on,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${entry.latitude?.toStringAsFixed(4)}, ${entry.longitude?.toStringAsFixed(4)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
                // Event reference - clickable to search for all contacts at this event
                if (entry.eventReference != null) ...[
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () {
                      // Navigate back to contacts list with event search
                      widget.onEventSearch?.call(entry.eventReference!);
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event,
                            size: 14,
                            color: theme.colorScheme.secondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${i18n.t('event')}: ${entry.eventReference}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.secondary,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.search,
                            size: 12,
                            color: theme.colorScheme.secondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
          ],
        ),
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

  Widget _buildDateReminderCardMobile(ContactDateReminder reminder) {
    final now = DateTime.now();
    final thisYear = now.year;

    // Calculate next occurrence
    var nextOccurrence = DateTime(thisYear, reminder.month, reminder.day);
    if (nextOccurrence.isBefore(now) || nextOccurrence.isAtSameMomentAs(now)) {
      nextOccurrence = DateTime(thisYear + 1, reminder.month, reminder.day);
    }

    final daysRemaining = nextOccurrence.difference(now).inDays;

    // Choose icon based on type
    IconData icon;
    Color iconColor;
    switch (reminder.type) {
      case ContactDateReminderType.birthday:
        icon = Icons.cake;
        iconColor = Colors.pink;
        break;
      case ContactDateReminderType.deceased:
        icon = Icons.favorite;
        iconColor = Colors.grey;
        break;
      case ContactDateReminderType.married:
        icon = Icons.favorite;
        iconColor = Colors.red;
        break;
      case ContactDateReminderType.relationStart:
        icon = Icons.people;
        iconColor = Colors.green;
        break;
      case ContactDateReminderType.relationEnd:
        icon = Icons.people_outline;
        iconColor = Colors.orange;
        break;
      case ContactDateReminderType.other:
        icon = Icons.event;
        iconColor = Colors.blue;
        break;
    }

    // Format days remaining text
    String daysText;
    if (daysRemaining == 0) {
      daysText = i18n.t('today');
    } else if (daysRemaining == 1) {
      daysText = i18n.t('tomorrow');
    } else {
      daysText = i18n.t('days_remaining', params: [daysRemaining.toString()]);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: iconColor.withValues(alpha: 0.15),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(reminder.displayType),
        subtitle: Text(reminder.displayDate),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: daysRemaining <= 7
                ? Colors.orange.withValues(alpha: 0.15)
                : Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            daysText,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: daysRemaining <= 7
                  ? Colors.orange.shade800
                  : Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCopyableRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(value),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: I18nService().t('copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(I18nService().t('copied_to_clipboard')),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneRowWithMetrics(_PhoneWithMetrics phoneData) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              i18n.t('phone'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(phoneData.phone),
                if (phoneData.interactionCount > 0)
                  Text(
                    i18n.t('times_called', params: [phoneData.interactionCount.toString()]),
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          // Show "most used" badge for the first one if it has interactions
          if (phoneData.interactionCount > 0 && _sortedPhones?.first == phoneData)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: Text(
                  i18n.t('most_used'),
                  style: const TextStyle(fontSize: 10),
                ),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: Colors.green.withAlpha(30),
              ),
            ),
          if (!kIsWeb && Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.phone, size: 20),
              tooltip: i18n.t('call'),
              onPressed: () => _launchPhoneCall(phoneData.phone, phoneData.index),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  Future<void> _launchPhoneCall(String phoneNumber, int index) async {
    // Record the interaction
    await contactService.recordMethodInteraction(
      contact.callsign,
      'phone',
      index,
      value: phoneNumber,
    );

    // Refresh metrics display
    final metrics = await contactService.getContactMetrics(contact.callsign);
    if (mounted) {
      setState(() {
        _metrics = metrics;
        _sortedPhones = _buildSortedPhones();
      });
    }

    // Launch the phone call
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Widget _buildEmailRowWithMetrics(_EmailWithMetrics emailData) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Email address on its own line
          Row(
            children: [
              Expanded(
                child: SelectableText(emailData.email),
              ),
              // Show "most used" badge for the first one if it has interactions
              if (emailData.interactionCount > 0 && _sortedEmails?.first == emailData)
                Chip(
                  label: Text(
                    i18n.t('most_used'),
                    style: const TextStyle(fontSize: 10),
                  ),
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: Colors.green.withAlpha(30),
                ),
            ],
          ),
          // Actions row below
          Row(
            children: [
              if (emailData.interactionCount > 0)
                Text(
                  i18n.t('times_emailed', params: [emailData.interactionCount.toString()]),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: i18n.t('copy'),
                onPressed: () => _copyEmail(emailData.email),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.email, size: 20),
                tooltip: i18n.t('send_email'),
                onPressed: () => _launchEmail(emailData.email, emailData.index),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _launchEmail(String email, int index) async {
    // Record the interaction
    await contactService.recordMethodInteraction(
      contact.callsign,
      'email',
      index,
      value: email,
    );

    // Refresh metrics display
    final metrics = await contactService.getContactMetrics(contact.callsign);
    if (mounted) {
      setState(() {
        _metrics = metrics;
        _sortedEmails = _buildSortedEmails();
      });
    }

    // Launch the email client
    final uri = Uri(scheme: 'mailto', path: email);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _copyEmail(String email) async {
    await Clipboard.setData(ClipboardData(text: email));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(i18n.t('copied_to_clipboard')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

/// Helper class for phone numbers with interaction metrics
class _PhoneWithMetrics {
  final String phone;
  final int index;
  final int interactionCount;

  _PhoneWithMetrics({
    required this.phone,
    required this.index,
    required this.interactionCount,
  });
}

/// Helper class for email addresses with interaction metrics
class _EmailWithMetrics {
  final String email;
  final int index;
  final int interactionCount;

  _EmailWithMetrics({
    required this.email,
    required this.index,
    required this.interactionCount,
  });
}

/// Dialog for picking an event to associate with a contact
class _EventPickerDialog extends StatefulWidget {
  final List<Event> events;
  final I18nService i18n;

  const _EventPickerDialog({
    required this.events,
    required this.i18n,
  });

  @override
  State<_EventPickerDialog> createState() => _EventPickerDialogState();
}

class _EventPickerDialogState extends State<_EventPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<Event> _filteredEvents = [];

  @override
  void initState() {
    super.initState();
    _filteredEvents = widget.events;
    _searchController.addListener(_filterEvents);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterEvents() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredEvents = widget.events;
      } else {
        _filteredEvents = widget.events.where((event) {
          return event.title.toLowerCase().contains(query) ||
              event.id.toLowerCase().contains(query) ||
              (event.locationName?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.i18n.t('select_event')),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            // Search bar
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: widget.i18n.t('search_events'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            // Event list
            Expanded(
              child: _filteredEvents.isEmpty
                  ? Center(child: Text(widget.i18n.t('no_events_found')))
                  : ListView.builder(
                      itemCount: _filteredEvents.length,
                      itemBuilder: (context, index) {
                        final event = _filteredEvents[index];
                        return ListTile(
                          leading: const Icon(Icons.event),
                          title: Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                event.displayDate,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (event.locationName != null)
                                Text(
                                  event.locationName!,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.secondary,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                          isThreeLine: event.locationName != null,
                          onTap: () => Navigator.pop(context, event),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
      ],
    );
  }
}
