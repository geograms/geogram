/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/app.dart';
import '../models/shared_folder.dart';
import '../models/group.dart';
import '../services/app_service.dart';
import '../services/i18n_service.dart';
import '../services/groups_service.dart';
import '../services/profile_storage.dart';
import '../services/shared_folder_service.dart';
import '../util/nostr_crypto.dart';
import 'contact_picker_page.dart';
import 'files_browser_page.dart';

/// Browser page for the "Shared" app — lists shared folder entries
class SharedBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;

  const SharedBrowserPage({
    super.key,
    required this.appPath,
    required this.appTitle,
  });

  @override
  State<SharedBrowserPage> createState() => _SharedBrowserPageState();
}

class _SharedBrowserPageState extends State<SharedBrowserPage> {
  final SharedFolderService _service = SharedFolderService();
  final I18nService _i18n = I18nService();

  List<SharedFolder> _folders = [];
  bool _isLoading = true;
  bool _hasMigrated = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Set up storage
    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      _service.setStorage(scopedStorage);
    } else {
      _service.setStorage(FilesystemProfileStorage(widget.appPath));
    }

    await _service.initializeApp(widget.appPath);

    // Run migration once if needed
    if (!_hasMigrated && profileStorage != null) {
      final existing = await _service.loadAll();
      if (existing.isEmpty) {
        await _service.migrateFromLegacy(profileStorage);
      }
      _hasMigrated = true;
    }

    await _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() => _isLoading = true);

    try {
      final folders = await _service.loadAll();
      setState(() {
        _folders = folders;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading shared folders: $e')),
        );
      }
    }
  }

  /// Load available groups for the restricted access picker
  Future<List<Group>> _loadAvailableGroups() async {
    try {
      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) return [];
      final apps = await AppService().loadApps();
      final groupsApp = apps.cast<App?>().firstWhere(
        (a) => a?.type == 'groups',
        orElse: () => null,
      );
      if (groupsApp?.storagePath == null) return [];
      final groupsStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage, groupsApp!.storagePath!,
      );
      final groupsService = GroupsService();
      groupsService.setStorage(groupsStorage);
      return await groupsService.loadGroups();
    } catch (e) {
      return [];
    }
  }

  /// Build the restricted access picker widgets (groups + contacts)
  /// allowedReaders is a map of hex pubkey → display label
  List<Widget> _buildRestrictedAccessWidgets({
    required BuildContext context,
    required List<Group> availableGroups,
    required Set<String> selectedGroups,
    required Map<String, String> allowedReaders,
    required void Function(void Function()) setDialogState,
  }) {
    return [
      const SizedBox(height: 16),

      // Groups section
      Text(
        _i18n.t('allowed_groups'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      if (availableGroups.isEmpty)
        Text(
          _i18n.t('no_groups_available'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        )
      else
        ...availableGroups.map((group) => CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(group.title),
          subtitle: Text('${group.memberCount} members'),
          value: selectedGroups.contains(group.name),
          onChanged: (checked) {
            setDialogState(() {
              if (checked == true) {
                selectedGroups.add(group.name);
              } else {
                selectedGroups.remove(group.name);
              }
            });
          },
        )),

      const SizedBox(height: 16),

      // Contacts section
      Text(
        _i18n.t('allowed_contacts'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () async {
          final results = await Navigator.push<List<ContactPickerResult>>(
            context,
            MaterialPageRoute(
              builder: (_) => ContactPickerPage(
                i18n: _i18n,
                multiSelect: true,
              ),
            ),
          );
          if (results != null) {
            setDialogState(() {
              for (final r in results) {
                final contact = r.contact;
                if (contact.npub != null && contact.npub!.isNotEmpty) {
                  try {
                    final hex = NostrCrypto.decodeNpub(contact.npub!);
                    if (hex.isNotEmpty) {
                      final label = contact.displayName.isNotEmpty
                          ? contact.displayName
                          : contact.callsign;
                      allowedReaders[hex] = label;
                    }
                  } catch (_) {}
                }
              }
            });
          }
        },
        icon: const Icon(Icons.person_add),
        label: Text(_i18n.t('add_contacts')),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 40),
        ),
      ),
      if (allowedReaders.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: allowedReaders.entries.map((entry) => Chip(
            label: Text(entry.value),
            deleteIcon: const Icon(Icons.close, size: 16),
            onDeleted: () {
              setDialogState(() {
                allowedReaders.remove(entry.key);
              });
            },
          )).toList(),
        ),
      ],
    ];
  }

  Future<void> _showAddDialog() async {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    String? selectedPath;
    String visibility = 'public';
    List<Group> availableGroups = [];
    final selectedGroups = <String>{};
    final allowedReaders = <String, String>{};

    final result = await showDialog<SharedFolder>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_i18n.t('add_shared_folder')),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title field
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: _i18n.t('title'),
                        hintText: _i18n.t('shared_folder_title_hint'),
                        prefixIcon: const Icon(Icons.title),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Folder picker
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final path =
                              await FilePicker.platform.getDirectoryPath(
                            dialogTitle: _i18n.t('select_folder'),
                          );
                          if (path != null) {
                            setDialogState(() => selectedPath = path);
                          }
                        } catch (e) {
                          // Ignore picker errors
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                      label: Text(_i18n.t('choose_folder')),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                    if (selectedPath != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                selectedPath!,
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Visibility dropdown
                    DropdownButtonFormField<String>(
                      value: visibility,
                      decoration: InputDecoration(
                        labelText: _i18n.t('visibility'),
                        prefixIcon: const Icon(Icons.visibility_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'public',
                          child: Text(_i18n.t('visibility_public')),
                        ),
                        DropdownMenuItem(
                          value: 'private',
                          child: Text(_i18n.t('visibility_private')),
                        ),
                        DropdownMenuItem(
                          value: 'restricted',
                          child: Text(_i18n.t('visibility_restricted')),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => visibility = value);
                          if (value == 'restricted' && availableGroups.isEmpty) {
                            _loadAvailableGroups().then((groups) {
                              setDialogState(() => availableGroups = groups);
                            });
                          }
                        }
                      },
                    ),

                    // Restricted access pickers
                    if (visibility == 'restricted')
                      ..._buildRestrictedAccessWidgets(
                        context: context,
                        availableGroups: availableGroups,
                        selectedGroups: selectedGroups,
                        allowedReaders: allowedReaders,
                        setDialogState: setDialogState,
                      ),

                    const SizedBox(height: 16),

                    // Description field
                    TextField(
                      controller: descController,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: _i18n.t('description'),
                        hintText: _i18n.t('optional'),
                        prefixIcon: const Icon(Icons.notes),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_i18n.t('cancel')),
              ),
              FilledButton(
                onPressed: () {
                  final title = titleController.text.trim();
                  if (title.isEmpty || selectedPath == null) return;

                  Navigator.pop(
                    context,
                    SharedFolder(
                      title: title,
                      location: selectedPath!,
                      visibility:
                          SharedFolderVisibility.fromValue(visibility),
                      allowedGroups: selectedGroups.toList(),
                      allowedReaders: allowedReaders.keys.toList(),
                      description: descController.text.trim(),
                    ),
                  );
                },
                child: Text(_i18n.t('add')),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      await _service.save(result);
      await _loadFolders();
    }
  }

  Future<void> _showEditDialog(SharedFolder folder) async {
    final titleController = TextEditingController(text: folder.title);
    final descController = TextEditingController(text: folder.description);
    String visibility = folder.visibility.value;
    List<Group> availableGroups = [];
    final selectedGroups = <String>{...folder.allowedGroups};
    // Initialize allowed readers map: hex pubkey → display label
    // For existing readers we show truncated hex as label (can't reverse to contact name)
    final allowedReaders = <String, String>{};
    for (final hex in folder.allowedReaders) {
      allowedReaders[hex] = '${hex.substring(0, 8)}...';
    }

    // Pre-load groups if editing a restricted folder
    if (visibility == 'restricted') {
      availableGroups = await _loadAvailableGroups();
    }

    if (!mounted) return;

    final result = await Navigator.push<SharedFolder>(
      context,
      MaterialPageRoute(
        builder: (_) => _EditSharedFolderPage(
          folder: folder,
          i18n: _i18n,
          initialVisibility: visibility,
          initialGroups: selectedGroups,
          initialAllowedReaders: allowedReaders,
          availableGroups: availableGroups,
          loadAvailableGroups: _loadAvailableGroups,
          buildRestrictedAccessWidgets: _buildRestrictedAccessWidgets,
        ),
      ),
    );

    if (result != null) {
      await _service.update(result);
      await _loadFolders();
    }
  }

  Future<void> _confirmDelete(SharedFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_shared_folder')),
        content: Text(_i18n.t('delete_shared_folder_confirm')),
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

    if (confirmed == true && folder.filePath != null) {
      await _service.delete(folder.filePath!);
      await _loadFolders();
    }
  }

  void _openFolder(SharedFolder folder) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FilesBrowserPage(
          appPath: folder.location,
          appTitle: folder.title,
          i18n: _i18n,
        ),
      ),
    );
  }

  IconData _getVisibilityIcon(SharedFolderVisibility visibility) {
    switch (visibility) {
      case SharedFolderVisibility.public:
        return Icons.public;
      case SharedFolderVisibility.private_:
        return Icons.lock;
      case SharedFolderVisibility.restricted:
        return Icons.group;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _folders.isEmpty
              ? _buildEmptyState(theme)
              : _buildFolderList(theme),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        tooltip: _i18n.t('add_shared_folder'),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_shared,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            _i18n.t('no_shared_folders'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _i18n.t('tap_plus_to_add_folder'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _folders.length,
      itemBuilder: (context, index) {
        final folder = _folders[index];
        return _buildFolderTile(folder, theme);
      },
    );
  }

  Widget _buildFolderTile(SharedFolder folder, ThemeData theme) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(
          Icons.folder_shared,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(
        folder.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            folder.location,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                _getVisibilityIcon(folder.visibility),
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                folder.visibility.displayName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (folder.visibility == SharedFolderVisibility.restricted) ...[
                const SizedBox(width: 8),
                Text(
                  '(${folder.allowedGroups.length} groups, ${folder.allowedReaders.length} contacts)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
              if (folder.description.isNotEmpty) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    folder.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) => _handleFolderMenuAction(folder, value),
        itemBuilder: (context) => [
          // Visibility options
          for (final vis in SharedFolderVisibility.values)
            PopupMenuItem(
              value: 'visibility_${vis.value}',
              child: Row(
                children: [
                  Icon(
                    _getVisibilityIcon(vis),
                    size: 18,
                    color: folder.visibility == vis
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _i18n.t('visibility_${vis.value}'),
                    style: folder.visibility == vis
                        ? TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                  ),
                  if (folder.visibility == vis) ...[
                    const Spacer(),
                    Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
                  ],
                ],
              ),
            ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                const Icon(Icons.edit, size: 18),
                const SizedBox(width: 12),
                Text(_i18n.t('edit')),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                const Icon(Icons.delete, size: 18, color: Colors.red),
                const SizedBox(width: 12),
                Text(
                  _i18n.t('delete'),
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ),
          ),
        ],
      ),
      onTap: () => _openFolder(folder),
    );
  }

  Future<void> _handleFolderMenuAction(SharedFolder folder, String action) async {
    if (action == 'edit') {
      _showEditDialog(folder);
      return;
    }
    if (action == 'delete') {
      _confirmDelete(folder);
      return;
    }
    if (action.startsWith('visibility_')) {
      final visValue = action.substring('visibility_'.length);
      final newVis = SharedFolderVisibility.fromValue(visValue);
      if (newVis == folder.visibility) return;

      // If changing to restricted, open edit dialog so user can configure access
      if (newVis == SharedFolderVisibility.restricted) {
        _showEditDialog(folder.copyWith(visibility: newVis));
        return;
      }

      // For public/private, just update directly
      final updated = folder.copyWith(visibility: newVis);
      await _service.update(updated);
      await _loadFolders();
    }
  }
}

/// Full-screen page for editing a shared folder
class _EditSharedFolderPage extends StatefulWidget {
  final SharedFolder folder;
  final I18nService i18n;
  final String initialVisibility;
  final Set<String> initialGroups;
  final Map<String, String> initialAllowedReaders;
  final List<Group> availableGroups;
  final Future<List<Group>> Function() loadAvailableGroups;
  final List<Widget> Function({
    required BuildContext context,
    required List<Group> availableGroups,
    required Set<String> selectedGroups,
    required Map<String, String> allowedReaders,
    required void Function(void Function()) setDialogState,
  }) buildRestrictedAccessWidgets;

  const _EditSharedFolderPage({
    required this.folder,
    required this.i18n,
    required this.initialVisibility,
    required this.initialGroups,
    required this.initialAllowedReaders,
    required this.availableGroups,
    required this.loadAvailableGroups,
    required this.buildRestrictedAccessWidgets,
  });

  @override
  State<_EditSharedFolderPage> createState() => _EditSharedFolderPageState();
}

class _EditSharedFolderPageState extends State<_EditSharedFolderPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _descController;
  late String _visibility;
  late List<Group> _availableGroups;
  late final Set<String> _selectedGroups;
  late final Map<String, String> _allowedReaders;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.folder.title);
    _descController = TextEditingController(text: widget.folder.description);
    _visibility = widget.initialVisibility;
    _availableGroups = List.from(widget.availableGroups);
    _selectedGroups = Set.from(widget.initialGroups);
    _allowedReaders = Map.from(widget.initialAllowedReaders);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.pop(
      context,
      widget.folder.copyWith(
        title: title,
        visibility: SharedFolderVisibility.fromValue(_visibility),
        allowedGroups: _selectedGroups.toList(),
        allowedReaders: _visibility == 'restricted'
            ? _allowedReaders.keys.toList()
            : null,
        description: _descController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.i18n.t('edit_shared_folder')),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(widget.i18n.t('save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Title
          TextField(
            controller: _titleController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.i18n.t('title'),
              prefixIcon: const Icon(Icons.title),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Location (read-only)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.folder.location,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Visibility
          DropdownButtonFormField<String>(
            value: _visibility,
            decoration: InputDecoration(
              labelText: widget.i18n.t('visibility'),
              prefixIcon: const Icon(Icons.visibility_outlined),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            items: [
              DropdownMenuItem(
                value: 'public',
                child: Text(widget.i18n.t('visibility_public')),
              ),
              DropdownMenuItem(
                value: 'private',
                child: Text(widget.i18n.t('visibility_private')),
              ),
              DropdownMenuItem(
                value: 'restricted',
                child: Text(widget.i18n.t('visibility_restricted')),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _visibility = value);
                if (value == 'restricted' && _availableGroups.isEmpty) {
                  widget.loadAvailableGroups().then((groups) {
                    setState(() => _availableGroups = groups);
                  });
                }
              }
            },
          ),

          // Restricted access pickers
          if (_visibility == 'restricted')
            ...widget.buildRestrictedAccessWidgets(
              context: context,
              availableGroups: _availableGroups,
              selectedGroups: _selectedGroups,
              allowedReaders: _allowedReaders,
              setDialogState: (fn) => setState(fn),
            ),

          const SizedBox(height: 16),

          // Description
          TextField(
            controller: _descController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: widget.i18n.t('description'),
              hintText: widget.i18n.t('optional'),
              prefixIcon: const Icon(Icons.notes),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Save button at the bottom
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: Text(widget.i18n.t('save')),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      ),
    );
  }
}
