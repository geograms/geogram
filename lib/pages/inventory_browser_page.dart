/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../inventory/models/inventory_folder.dart';
import '../inventory/models/inventory_item.dart';
import '../inventory/services/inventory_service.dart';
import '../inventory/utils/inventory_folder_utils.dart';
import '../services/i18n_service.dart';
import '../widgets/inventory/folder_tree_widget.dart';
import '../widgets/inventory/item_card_widget.dart';
import 'inventory_item_page.dart';

/// Main inventory browser page with two-panel layout
class InventoryBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;
  final I18nService i18n;

  const InventoryBrowserPage({
    super.key,
    required this.collectionPath,
    required this.collectionTitle,
    required this.i18n,
  });

  @override
  State<InventoryBrowserPage> createState() => _InventoryBrowserPageState();
}

class _InventoryBrowserPageState extends State<InventoryBrowserPage> {
  final InventoryService _service = InventoryService();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedItems = {};
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  List<String> _currentPath = [];
  List<InventoryItem> _items = [];
  List<InventoryFolder> _subfolders = [];
  List<InventoryItem> _templateItems = [];
  InventoryFolder? _currentFolder;
  bool _loading = true;
  bool _selectionMode = false;
  bool _searchMode = false;
  String _searchQuery = '';
  int _folderTreeKey = 0;
  StreamSubscription? _changesSub;

  late String _langCode;

  @override
  void initState() {
    super.initState();
    _langCode = widget.i18n.currentLanguage.split('_').first.toUpperCase();
    _initializeService();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _changesSub?.cancel();
    super.dispose();
  }

  Future<void> _initializeService() async {
    await _service.initializeCollection(widget.collectionPath);
    _changesSub = _service.changes.listen(_onInventoryChange);
    await _loadTemplateItems();
    await _loadContents();

    // Auto-select first folder if no path is selected and folders exist
    if (_currentPath.isEmpty) {
      final rootFolders = await _service.getRootFolders();
      // Filter out the templates folder from root folders for auto-selection
      final nonTemplateFolders = rootFolders
          .where((f) => f.id != InventoryService.templatesFolderId)
          .toList();
      if (nonTemplateFolders.isNotEmpty && mounted) {
        _navigateToFolder([nonTemplateFolders.first.id]);
      }
    }
  }

  Future<void> _loadTemplateItems() async {
    try {
      _templateItems = await _service.getTemplateItems();
    } catch (e) {
      _templateItems = [];
    }
  }

  void _onInventoryChange(InventoryChange change) {
    // Reload if change affects current view
    if (change.folderPath == null ||
        InventoryFolderUtils.joinFolderPath(change.folderPath!) ==
            InventoryFolderUtils.joinFolderPath(_currentPath) ||
        change.type == InventoryChangeType.itemMoved) {
      _loadContents();
    }
  }

  String _getDisplayTitle() {
    // If the title looks like a translation key, translate it
    if (widget.collectionTitle.startsWith('collection_type_')) {
      return widget.i18n.t(widget.collectionTitle);
    }
    return widget.collectionTitle;
  }

  void _toggleSearch() {
    setState(() {
      _searchMode = !_searchMode;
      if (!_searchMode) {
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query.toLowerCase();
    });
  }

  List<InventoryItem> get _filteredItems {
    if (_searchQuery.isEmpty) return _items;
    return _items.where((item) {
      final title = item.getTitle(_langCode).toLowerCase();
      final type = item.type.toLowerCase();
      return title.contains(_searchQuery) || type.contains(_searchQuery);
    }).toList();
  }

  Future<void> _loadContents() async {
    setState(() => _loading = true);
    try {
      _items = await _service.getItems(_currentPath);
      _subfolders = await _service.getSubfolders(_currentPath);
      if (_currentPath.isNotEmpty) {
        _currentFolder = await _service.getFolder(_currentPath);
      } else {
        _currentFolder = null;
      }
    } catch (e) {
      // Handle error
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  void _navigateToFolder(List<String> folderPath) {
    setState(() {
      _currentPath = folderPath;
      _selectionMode = false;
      _selectedItems.clear();
    });
    _loadContents();
  }

  Future<void> _createFolder() async {
    final name = await _showCreateFolderDialog();
    if (name == null || name.isEmpty) return;

    await _service.createFolder(
      name: name,
      parentPath: _currentPath,
    );

    setState(() => _folderTreeKey++);
    await _loadContents();
  }

  Future<String?> _showCreateFolderDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_create_folder')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.i18n.t('inventory_folder_name'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(widget.i18n.t('create')),
          ),
        ],
      ),
    );
  }

  Future<void> _createItem() async {
    // If templates exist, show menu to choose between template and new item
    if (_templateItems.isNotEmpty) {
      _showAddItemMenu();
    } else {
      _createNewItem();
    }
  }

  void _showAddItemMenu() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              width: double.infinity,
              child: Text(
                widget.i18n.t('inventory_add_item'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Divider(height: 1),
            // New Item from scratch
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: Text(widget.i18n.t('inventory_new_item')),
              onTap: () {
                Navigator.pop(context);
                _createNewItem();
              },
            ),
            // Use template
            ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: Text(widget.i18n.t('inventory_use_template')),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_templateItems.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _showTemplateSelector();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showTemplateSelector() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SafeArea(
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                width: double.infinity,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.i18n.t('inventory_templates'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Template list
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: _templateItems.length,
                  itemBuilder: (context, index) {
                    final template = _templateItems[index];
                    return ListTile(
                      leading: Icon(
                        Icons.description_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(template.getTitle(_langCode)),
                      subtitle: template.type.isNotEmpty
                          ? Text(template.type)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        _createItemFromTemplate(template);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createNewItem() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => InventoryItemPage(
          collectionPath: widget.collectionPath,
          folderPath: _currentPath,
          i18n: widget.i18n,
        ),
      ),
    );
    if (result == true) {
      await _loadContents();
    }
  }

  Future<void> _createItemFromTemplate(InventoryItem template) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => InventoryItemPage(
          collectionPath: widget.collectionPath,
          folderPath: _currentPath,
          i18n: widget.i18n,
          templateItem: template,
        ),
      ),
    );
    if (result == true) {
      await _loadContents();
    }
  }

  Future<void> _editItem(InventoryItem item) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => InventoryItemPage(
          collectionPath: widget.collectionPath,
          folderPath: _currentPath,
          item: item,
          i18n: widget.i18n,
        ),
      ),
    );
    if (result == true) {
      await _loadContents();
    }
  }

  void _toggleSelection(String itemId) {
    setState(() {
      if (_selectedItems.contains(itemId)) {
        _selectedItems.remove(itemId);
        if (_selectedItems.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectedItems.add(itemId);
      }
    });
  }

  void _enterSelectionMode(String itemId) {
    setState(() {
      _selectionMode = true;
      _selectedItems.add(itemId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedItems.clear();
    });
  }

  Future<void> _deleteSelectedItems() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_delete_items')),
        content: Text(widget.i18n.t('inventory_delete_items_confirm')
            .replaceAll('{count}', _selectedItems.length.toString())),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final itemId in _selectedItems) {
        await _service.deleteItem(_currentPath, itemId);
      }
      _exitSelectionMode();
    }
  }

  /// Show bottom sheet menu for item actions (mobile)
  void _showItemOptionsMenu(InventoryItem item) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with item title
            Container(
              padding: const EdgeInsets.all(16),
              width: double.infinity,
              child: Text(
                item.getTitle(_langCode),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            // Move to Folder
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: Text(widget.i18n.t('inventory_move_to_folder')),
              onTap: () {
                Navigator.pop(context);
                _showFolderPickerDialog(item);
              },
            ),
            // Rename
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(widget.i18n.t('rename')),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(item);
              },
            ),
            // Delete
            ListTile(
              leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              title: Text(
                widget.i18n.t('delete'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(context);
                _deleteItem(item);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Show folder picker dialog for moving an item
  Future<void> _showFolderPickerDialog(InventoryItem item) async {
    final selectedPath = await showDialog<List<String>>(
      context: context,
      builder: (context) => _FolderPickerDialog(
        i18n: widget.i18n,
        currentPath: _currentPath,
        excludePath: _currentPath,
      ),
    );

    if (selectedPath != null) {
      await _moveItem(item, selectedPath);
    }
  }

  /// Move item to a different folder
  Future<void> _moveItem(InventoryItem item, List<String> targetPath) async {
    try {
      await _service.moveItem(_currentPath, item.id, targetPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_item_moved'))),
        );
        setState(() => _folderTreeKey++);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('error'))),
        );
      }
    }
  }

  /// Show rename dialog
  Future<void> _showRenameDialog(InventoryItem item) async {
    final controller = TextEditingController(text: item.getTitle(_langCode));
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.i18n.t('inventory_item_title'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(widget.i18n.t('save')),
          ),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty && newTitle != item.title) {
      await _renameItem(item, newTitle);
    }
  }

  /// Rename an item
  Future<void> _renameItem(InventoryItem item, String newTitle) async {
    try {
      final updatedItem = item.copyWith(title: newTitle);
      await _service.updateItem(_currentPath, updatedItem);
      await _loadContents();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('error'))),
        );
      }
    }
  }

  /// Handle item dropped on folder (drag & drop)
  void _onItemDropped(dynamic item, List<String> targetPath) {
    if (item is InventoryItem) {
      // Don't move if dropping on same folder
      if (targetPath.join('/') == _currentPath.join('/')) return;
      _moveItem(item, targetPath);
    }
  }

  /// Handle folder action (rename/delete)
  void _onFolderAction(List<String> folderPath, String action) {
    switch (action) {
      case 'rename':
        _renameFolder(folderPath);
        break;
      case 'delete':
        _deleteFolderConfirm(folderPath);
        break;
    }
  }

  /// Rename a folder
  Future<void> _renameFolder(List<String> folderPath) async {
    final folder = await _service.getFolder(folderPath);
    if (folder == null) return;

    final controller = TextEditingController(text: folder.getName(_langCode));
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.i18n.t('inventory_folder_name'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(widget.i18n.t('save')),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != folder.name) {
      final success = await _service.renameFolder(folderPath, newName);
      if (success && mounted) {
        setState(() => _folderTreeKey++);
        await _loadContents();
      }
    }
  }

  /// Delete a folder with confirmation
  Future<void> _deleteFolderConfirm(List<String> folderPath) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_delete_folder')),
        content: Text(widget.i18n.t('inventory_delete_folder_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final success = await _service.deleteFolder(folderPath);
      if (success && mounted) {
        // If we deleted the current folder, navigate to parent
        if (_currentPath.join('/').startsWith(folderPath.join('/'))) {
          _navigateToFolder(folderPath.length > 1
              ? folderPath.sublist(0, folderPath.length - 1)
              : []);
        }
        setState(() => _folderTreeKey++);
      }
    }
  }

  /// Delete a single item
  Future<void> _deleteItem(InventoryItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_delete_item')),
        content: Text(widget.i18n.t('inventory_delete_item_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.deleteItem(_currentPath, item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width > 800;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isWide ? null : _buildDrawer(theme),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: _searchMode
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: widget.i18n.t('inventory_search_hint'),
                  border: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
              )
            : _selectionMode
                ? Text(widget.i18n.t('inventory_selected_count')
                    .replaceAll('{count}', _selectedItems.length.toString()))
                : Text(_getDisplayTitle()),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : _searchMode
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _toggleSearch,
                  )
                : IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                    tooltip: widget.i18n.t('back'),
                  ),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _selectedItems.isNotEmpty ? _deleteSelectedItems : null,
              tooltip: widget.i18n.t('delete'),
            ),
          ] else if (_searchMode) ...[
            if (_searchQuery.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _searchController.clear();
                  _onSearchChanged('');
                },
              ),
          ] else ...[
            if (!isWide)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
                tooltip: widget.i18n.t('close'),
              ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _toggleSearch,
              tooltip: widget.i18n.t('search'),
            ),
          ],
        ],
      ),
      body: isWide ? _buildWideLayout(theme) : _buildNarrowLayout(theme),
      floatingActionButton: !_selectionMode
          ? FloatingActionButton.extended(
              onPressed: _createItem,
              icon: const Icon(Icons.add),
              label: Text(widget.i18n.t('inventory_add_item')),
            )
          : null,
    );
  }

  Widget _buildWideLayout(ThemeData theme) {
    return Row(
      children: [
        // Folder tree
        SizedBox(
          width: 280,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: FolderTreeWidget(
                    key: ValueKey(_folderTreeKey),
                    i18n: widget.i18n,
                    selectedPath: _currentPath,
                    onFolderSelected: _navigateToFolder,
                    onCreateFolder: _createFolder,
                    onItemDropped: _onItemDropped,
                    onFolderAction: _onFolderAction,
                  ),
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: theme.dividerColor),
        // Items grid
        Expanded(
          child: _buildItemsView(theme),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout(ThemeData theme) {
    return Column(
      children: [
        // Breadcrumb / folder path
        _buildBreadcrumb(theme),
        Divider(height: 1, color: theme.dividerColor),
        // Folders and items list
        Expanded(
          child: _buildNarrowContentView(theme),
        ),
      ],
    );
  }

  Widget _buildNarrowContentView(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final items = _filteredItems;
    final hasSubfolders = _subfolders.isNotEmpty;
    final hasItems = items.isNotEmpty;
    final hasContent = hasSubfolders || hasItems;

    if (!hasContent) {
      // Show empty state
      final isSearching = _searchQuery.isNotEmpty;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSearching ? Icons.search_off : Icons.inventory_2_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              isSearching
                  ? widget.i18n.t('inventory_no_results')
                  : widget.i18n.t('inventory_empty_folder'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isSearching
                  ? widget.i18n.t('inventory_no_results_hint')
                  : widget.i18n.t('inventory_empty_folder_hint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        // Subfolders section
        if (hasSubfolders && _searchQuery.isEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Text(
                    widget.i18n.t('inventory_folders'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '(${_subfolders.length})',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final folder = _subfolders[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                        Icons.folder,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(folder.getName(_langCode)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _navigateToFolder([..._currentPath, folder.id]),
                    ),
                  );
                },
                childCount: _subfolders.length,
              ),
            ),
          ),
        ],
        // Items section
        if (hasItems) ...[
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Text(
                    widget.i18n.t('inventory_items'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '(${items.length})',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 0.75,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = items[index];
                  return ItemCardWidget(
                    item: item,
                    i18n: widget.i18n,
                    mediaBasePath: _getMediaPath(),
                    isSelected: _selectedItems.contains(item.id),
                    onTap: _selectionMode
                        ? () => _toggleSelection(item.id)
                        : () => _editItem(item),
                    onLongPress: _selectionMode
                        ? null
                        : () => _showItemOptionsMenu(item),
                  );
                },
                childCount: items.length,
              ),
            ),
          ),
        ],
        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }

  Widget _buildDrawer(ThemeData theme) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Drawer header
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.i18n.t('inventory_folders'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () {
                      Navigator.pop(context);
                      _createFolder();
                    },
                    tooltip: widget.i18n.t('inventory_create_folder'),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: theme.dividerColor),
            // Folder tree
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: FolderTreeWidget(
                  key: ValueKey(_folderTreeKey),
                  i18n: widget.i18n,
                  selectedPath: _currentPath,
                  onFolderSelected: (path) {
                    Navigator.pop(context);
                    _navigateToFolder(path);
                  },
                  onCreateFolder: () {
                    Navigator.pop(context);
                    _createFolder();
                  },
                  onFolderAction: (path, action) {
                    Navigator.pop(context);
                    _onFolderAction(path, action);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumb(ThemeData theme) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // Root button
          TextButton.icon(
            onPressed: _currentPath.isEmpty ? null : () => _navigateToFolder([]),
            icon: const Icon(Icons.inventory_2, size: 18),
            label: Text(widget.i18n.t('inventory_all_items')),
            style: TextButton.styleFrom(
              foregroundColor: _currentPath.isEmpty
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          // Path segments
          ..._buildPathSegments(theme),
          const Spacer(),
          // Create folder button
          if (_currentPath.length < InventoryFolder.maxDepth)
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              onPressed: _createFolder,
              tooltip: widget.i18n.t('inventory_create_folder'),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildPathSegments(ThemeData theme) {
    final widgets = <Widget>[];
    for (int i = 0; i < _currentPath.length; i++) {
      final isLast = i == _currentPath.length - 1;
      final segmentPath = _currentPath.sublist(0, i + 1);

      widgets.add(Icon(
        Icons.chevron_right,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ));

      widgets.add(TextButton(
        onPressed: isLast ? null : () => _navigateToFolder(segmentPath),
        style: TextButton.styleFrom(
          foregroundColor: isLast
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface,
        ),
        child: FutureBuilder<InventoryFolder?>(
          future: _service.getFolder(segmentPath),
          builder: (context, snapshot) {
            final name = snapshot.data?.getName(_langCode) ?? _currentPath[i];
            return Text(name);
          },
        ),
      ));
    }
    return widgets;
  }

  Widget _buildItemsView(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final items = _filteredItems;
    final hasContent = items.isNotEmpty;

    if (!hasContent) {
      // Show different message when searching vs empty folder
      final isSearching = _searchQuery.isNotEmpty;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSearching ? Icons.search_off : Icons.inventory_2_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              isSearching
                  ? widget.i18n.t('inventory_no_results')
                  : widget.i18n.t('inventory_empty_folder'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isSearching
                  ? widget.i18n.t('inventory_no_results_hint')
                  : widget.i18n.t('inventory_empty_folder_hint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        // Items header
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  widget.i18n.t('inventory_items'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${items.length})',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Items grid
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              childAspectRatio: 0.75,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = items[index];
                final card = ItemCardWidget(
                  item: item,
                  i18n: widget.i18n,
                  mediaBasePath: _getMediaPath(),
                  isSelected: _selectedItems.contains(item.id),
                  onTap: _selectionMode
                      ? () => _toggleSelection(item.id)
                      : () => _editItem(item),
                  onLongPress: _selectionMode
                      ? null
                      : () => _showItemOptionsMenu(item),
                );
                // Wrap with Draggable for desktop drag & drop
                return Draggable<InventoryItem>(
                  data: item,
                  feedback: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 180,
                      child: Opacity(
                        opacity: 0.9,
                        child: card,
                      ),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.4,
                    child: card,
                  ),
                  child: card,
                );
              },
              childCount: items.length,
            ),
          ),
        ),
        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }

  String _getMediaPath() {
    return InventoryFolderUtils.buildMediaPath(
      widget.collectionPath,
      _currentPath,
    );
  }
}

/// Dialog for selecting a folder to move items to
class _FolderPickerDialog extends StatefulWidget {
  final I18nService i18n;
  final List<String> currentPath;
  final List<String> excludePath;

  const _FolderPickerDialog({
    required this.i18n,
    required this.currentPath,
    required this.excludePath,
  });

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  final InventoryService _service = InventoryService();
  final Map<String, bool> _expanded = {};
  final Map<String, List<InventoryFolder>> _subfolders = {};
  List<InventoryFolder> _rootFolders = [];
  List<String>? _selectedPath;
  bool _loading = true;
  late String _langCode;

  @override
  void initState() {
    super.initState();
    _langCode = widget.i18n.currentLanguage.split('_').first.toUpperCase();
    _loadRootFolders();
  }

  Future<void> _loadRootFolders() async {
    setState(() => _loading = true);
    try {
      _rootFolders = await _service.getRootFolders();
    } catch (e) {
      // Handle error
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadSubfolders(List<String> folderPath) async {
    final key = folderPath.join('/');
    if (_subfolders.containsKey(key)) return;

    try {
      final folders = await _service.getSubfolders(folderPath);
      if (mounted) {
        setState(() {
          _subfolders[key] = folders;
        });
      }
    } catch (e) {
      // Handle error
    }
  }

  void _toggleExpanded(List<String> folderPath) async {
    final key = folderPath.join('/');
    final isExpanded = _expanded[key] ?? false;

    if (!isExpanded) {
      await _loadSubfolders(folderPath);
    }

    setState(() {
      _expanded[key] = !isExpanded;
    });
  }

  bool _isExcluded(List<String> folderPath) {
    // Can't move to current folder
    if (folderPath.length != widget.excludePath.length) return false;
    for (int i = 0; i < folderPath.length; i++) {
      if (folderPath[i] != widget.excludePath[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.i18n.t('inventory_select_folder')),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Root (All Items) entry
                    _buildFolderTile(
                      theme,
                      folderPath: [],
                      name: widget.i18n.t('inventory_root_folder'),
                      icon: Icons.inventory_2,
                      depth: 0,
                      hasSubfolders: _rootFolders.isNotEmpty,
                    ),
                    // Root folders
                    ..._rootFolders.map((folder) => _buildFolderTree(
                          theme,
                          folder,
                          [folder.id],
                        )),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _selectedPath != null
              ? () => Navigator.pop(context, _selectedPath)
              : null,
          child: Text(widget.i18n.t('move')),
        ),
      ],
    );
  }

  Widget _buildFolderTree(
    ThemeData theme,
    InventoryFolder folder,
    List<String> folderPath,
  ) {
    final key = folderPath.join('/');
    final isExpanded = _expanded[key] ?? false;
    final subfolders = _subfolders[key] ?? [];
    final canHaveSubfolders = folder.canCreateSubfolder;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFolderTile(
          theme,
          folderPath: folderPath,
          name: folder.getName(_langCode),
          icon: Icons.folder,
          depth: folder.depth,
          hasSubfolders: canHaveSubfolders,
          isExpanded: isExpanded,
          onExpand: canHaveSubfolders ? () => _toggleExpanded(folderPath) : null,
        ),
        if (isExpanded)
          ...subfolders.map((subfolder) => _buildFolderTree(
                theme,
                subfolder,
                [...folderPath, subfolder.id],
              )),
      ],
    );
  }

  Widget _buildFolderTile(
    ThemeData theme, {
    required List<String> folderPath,
    required String name,
    required IconData icon,
    required int depth,
    bool hasSubfolders = false,
    bool isExpanded = false,
    VoidCallback? onExpand,
  }) {
    final isSelected = _selectedPath != null &&
        _selectedPath!.length == folderPath.length &&
        List.generate(folderPath.length, (i) => _selectedPath![i] == folderPath[i])
            .every((e) => e);
    final isExcluded = _isExcluded(folderPath);
    final leftPadding = 8.0 + (depth * 16.0);

    return Opacity(
      opacity: isExcluded ? 0.5 : 1.0,
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: isExcluded ? null : () => setState(() => _selectedPath = folderPath),
          child: Padding(
            padding: EdgeInsets.only(
              left: leftPadding,
              right: 8,
              top: 10,
              bottom: 10,
            ),
            child: Row(
              children: [
                if (hasSubfolders && onExpand != null)
                  GestureDetector(
                    onTap: onExpand,
                    child: Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  const SizedBox(width: 20),
                const SizedBox(width: 4),
                Icon(
                  icon,
                  size: 20,
                  color: isSelected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isSelected
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurface,
                      fontWeight: isSelected ? FontWeight.w500 : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isExcluded)
                  Text(
                    '(${widget.i18n.t('current')})',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
