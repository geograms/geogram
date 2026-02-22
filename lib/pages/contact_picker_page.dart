/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/app.dart';
import '../models/contact.dart';
import '../services/app_service.dart';
import '../services/contact_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_storage.dart';

/// Result returned when a contact is selected
class ContactPickerResult {
  final Contact contact;
  final String? appTitle;

  ContactPickerResult({
    required this.contact,
    this.appTitle,
  });
}

/// Sort modes for contacts
enum _SortMode { popular, alphabetical, recent }

/// Full-screen contact picker page
///
/// Shows all contacts from the user's contact collections with search
/// and sorting functionality.
///
/// Example usage:
/// ```dart
/// final result = await Navigator.push<ContactPickerResult>(
///   context,
///   MaterialPageRoute(
///     builder: (context) => ContactPickerPage(i18n: widget.i18n),
///   ),
/// );
///
/// if (result != null) {
///   print('Selected: ${result.contact.displayName}');
///   print('Callsign: ${result.contact.callsign}');
/// }
/// ```
class ContactPickerPage extends StatefulWidget {
  final I18nService i18n;

  /// Optional: allow multiple selection
  final bool multiSelect;

  /// Optional: pre-selected contact callsigns (for multi-select mode)
  final Set<String>? initialSelection;

  /// Optional: sort by event associations (for event contact picker)
  final bool sortByEvents;

  const ContactPickerPage({
    super.key,
    required this.i18n,
    this.multiSelect = false,
    this.initialSelection,
    this.sortByEvents = false,
  });

  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  final TextEditingController _searchController = TextEditingController();
  final List<_ContactWithApp> _contacts = [];
  List<_ContactWithApp> _filtered = [];
  bool _isLoading = true;
  _SortMode _sortMode = _SortMode.popular;
  final Set<String> _selectedCallsigns = {};
  Set<String> _favoriteCallsigns = {};
  Map<String, int> _eventCounts = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialSelection != null) {
      _selectedCallsigns.addAll(widget.initialSelection!);
    }
    _searchController.addListener(_applyFilter);
    _loadContacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final collectionService = AppService();
      final app = collectionService.getAppByType('contacts');
      final contactCollections = app != null ? [app] : <App>[];

      _contacts.clear();
      final contactService = ContactService();
      final profileStorage = collectionService.profileStorage;

      for (final collection in contactCollections) {
        // Set up storage for this collection
        if (profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            profileStorage,
            collection.storagePath!,
          );
          contactService.setStorage(scopedStorage);
        } else {
          contactService.setStorage(FilesystemProfileStorage(collection.storagePath!));
        }

        await contactService.initializeApp(collection.storagePath!);

        // Load favorites (instant from cache)
        final favorites = await contactService.loadFavorites();
        _favoriteCallsigns = favorites.map((f) => f.callsign).toSet();

        // Load event counts if sorting by events
        if (widget.sortByEvents) {
          final metrics = await contactService.loadMetrics();
          _eventCounts = {};
          for (final entry in metrics.contacts.entries) {
            if (entry.value.events > 0) {
              _eventCounts[entry.key] = entry.value.events;
            }
          }
        }

        await for (final contact
            in contactService.loadAllContactsStreamFast()) {
          _contacts.add(_ContactWithApp(contact, collection.title));
        }
      }

      _sortContacts();
    } catch (e) {
      _contacts.clear();
    }

    if (mounted) {
      setState(() {
        _filtered = List.from(_contacts);
        _isLoading = false;
      });
    }
  }

  void _sortContacts() {
    // Contacts with nicknames always sort above callsign-only contacts
    int nicknameFirst(_ContactWithApp a, _ContactWithApp b) {
      final aHas = _hasNickname(a.contact);
      final bHas = _hasNickname(b.contact);
      if (aHas && !bHas) return -1;
      if (!aHas && bHas) return 1;
      return 0; // equal tier
    }

    switch (_sortMode) {
      case _SortMode.popular:
        if (widget.sortByEvents && _eventCounts.isNotEmpty) {
          _contacts.sort((a, b) {
            final n = nicknameFirst(a, b);
            if (n != 0) return n;
            final aEvents = _eventCounts[a.contact.callsign] ?? 0;
            final bEvents = _eventCounts[b.contact.callsign] ?? 0;
            if (aEvents != bEvents) return bEvents.compareTo(aEvents);
            final aIsFavorite = _favoriteCallsigns.contains(a.contact.callsign);
            final bIsFavorite = _favoriteCallsigns.contains(b.contact.callsign);
            if (aIsFavorite && !bIsFavorite) return -1;
            if (!aIsFavorite && bIsFavorite) return 1;
            return a.contact.displayName
                .toLowerCase()
                .compareTo(b.contact.displayName.toLowerCase());
          });
        } else {
          _contacts.sort((a, b) {
            final n = nicknameFirst(a, b);
            if (n != 0) return n;
            final aIsFavorite = _favoriteCallsigns.contains(a.contact.callsign);
            final bIsFavorite = _favoriteCallsigns.contains(b.contact.callsign);
            if (aIsFavorite && !bIsFavorite) return -1;
            if (!aIsFavorite && bIsFavorite) return 1;
            return a.contact.displayName
                .toLowerCase()
                .compareTo(b.contact.displayName.toLowerCase());
          });
        }
        break;
      case _SortMode.alphabetical:
        _contacts.sort((a, b) {
          final n = nicknameFirst(a, b);
          if (n != 0) return n;
          return a.contact.displayName
              .toLowerCase()
              .compareTo(b.contact.displayName.toLowerCase());
        });
        break;
      case _SortMode.recent:
        _contacts.sort((a, b) {
          final n = nicknameFirst(a, b);
          if (n != 0) return n;
          final aDate = a.contact.firstSeenDateTime;
          final bDate = b.contact.firstSeenDateTime;
          return bDate.compareTo(aDate);
        });
        break;
    }
  }

  void _toggleSortMode() {
    setState(() {
      // Cycle through: popular -> alphabetical -> recent -> popular
      switch (_sortMode) {
        case _SortMode.popular:
          _sortMode = _SortMode.alphabetical;
          break;
        case _SortMode.alphabetical:
          _sortMode = _SortMode.recent;
          break;
        case _SortMode.recent:
          _sortMode = _SortMode.popular;
          break;
      }
      _sortContacts();
      _applyFilter();
    });
  }

  void _applyFilter() {
    final query = _searchController.text.trim().toLowerCase();
    List<_ContactWithApp> result;

    if (query.isEmpty) {
      result = List.from(_contacts);
    } else {
      result = _contacts.where((item) {
        final contact = item.contact;
        // Search across multiple fields
        final searchableFields = [
          contact.displayName,
          contact.callsign,
          contact.groupPath ?? '',
          item.appTitle ?? '',
          ...contact.emails,
          ...contact.phones,
          ...contact.tags,
          contact.notes,
        ];
        final searchText = searchableFields.join(' ').toLowerCase();
        return searchText.contains(query);
      }).toList();
    }

    // In multi-select mode, pin selected contacts at the top
    if (widget.multiSelect && _selectedCallsigns.isNotEmpty) {
      final selected = <_ContactWithApp>[];
      final unselected = <_ContactWithApp>[];
      for (final item in result) {
        if (_selectedCallsigns.contains(item.contact.callsign)) {
          selected.add(item);
        } else {
          unselected.add(item);
        }
      }
      result = [...selected, ...unselected];
    }

    setState(() {
      _filtered = result;
    });
  }

  void _selectContact(_ContactWithApp item) {
    if (widget.multiSelect) {
      if (_selectedCallsigns.contains(item.contact.callsign)) {
        _selectedCallsigns.remove(item.contact.callsign);
      } else {
        _selectedCallsigns.add(item.contact.callsign);
      }
      // Re-apply filter to re-sort with selected contacts at top
      _applyFilter();
    } else {
      Navigator.pop(
        context,
        ContactPickerResult(
          contact: item.contact,
          appTitle: item.appTitle,
        ),
      );
    }
  }

  void _confirmMultiSelect() {
    // Return all selected contacts
    final selectedContacts = _contacts
        .where((item) => _selectedCallsigns.contains(item.contact.callsign))
        .map((item) => ContactPickerResult(
              contact: item.contact,
              appTitle: item.appTitle,
            ))
        .toList();
    Navigator.pop(context, selectedContacts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.i18n.t('select_contact')),
        actions: [
          if (widget.multiSelect && _selectedCallsigns.isNotEmpty)
            TextButton.icon(
              onPressed: _confirmMultiSelect,
              icon: const Icon(Icons.check),
              label: Text('${_selectedCallsigns.length}'),
            ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: widget.i18n.t('search_contacts'),
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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

          // Sort toggle
          if (!_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: InkWell(
                onTap: _toggleSortMode,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _sortMode == _SortMode.popular
                            ? Icons.star
                            : _sortMode == _SortMode.alphabetical
                                ? Icons.sort_by_alpha
                                : Icons.access_time,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _sortMode == _SortMode.popular
                            ? widget.i18n.t('sorted_by_popular')
                            : _sortMode == _SortMode.alphabetical
                                ? widget.i18n.t('sorted_alphabetically')
                                : widget.i18n.t('sorted_by_recent'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.swap_vert,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          const SizedBox(height: 8),

          // Contacts list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.person_search,
                              size: 64,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withOpacity(0.5),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              widget.i18n.t('no_contacts_found'),
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filtered.length,
                        itemBuilder: (context, index) {
                          final item = _filtered[index];
                          final isSelected = _selectedCallsigns
                              .contains(item.contact.callsign);
                          return _buildContactTile(item, isSelected, theme);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(
      _ContactWithApp item, bool isSelected, ThemeData theme) {
    final contact = item.contact;

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              contact.displayName.isNotEmpty
                  ? contact.displayName[0].toUpperCase()
                  : '?',
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (widget.multiSelect && isSelected)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check,
                  size: 12,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
      title: Text(
        _hasNickname(contact)
            ? '${contact.displayName} (${contact.callsign})'
            : contact.callsign,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : null,
        ),
      ),
      subtitle: Text(
        _buildSubtitle(item),
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: theme.colorScheme.onSurfaceVariant,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: widget.multiSelect
          ? Checkbox(
              value: isSelected,
              onChanged: (_) => _selectContact(item),
            )
          : Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      selected: isSelected,
      onTap: () => _selectContact(item),
    );
  }

  bool _hasNickname(Contact contact) {
    return contact.displayName.isNotEmpty &&
        contact.displayName != contact.callsign;
  }

  String _buildSubtitle(_ContactWithApp item) {
    final parts = <String>[];
    if (item.contact.groupPath?.isNotEmpty == true) {
      parts.add(item.contact.groupPath!);
    }
    if (item.appTitle?.isNotEmpty == true) {
      parts.add(item.appTitle!);
    }
    return parts.join(' • ');
  }
}

/// Internal class to hold contact with its collection info
class _ContactWithApp {
  final Contact contact;
  final String? appTitle;

  _ContactWithApp(this.contact, this.appTitle);
}
