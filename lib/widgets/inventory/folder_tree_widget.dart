/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../inventory/models/inventory_folder.dart';
import '../../inventory/services/inventory_service.dart';
import '../../services/i18n_service.dart';

/// Callback type for item drop events
typedef OnItemDropped = void Function(dynamic item, List<String> targetPath);

/// Callback type for folder actions
typedef OnFolderAction = void Function(List<String> folderPath, String action);

/// Widget for displaying the folder tree navigation
class FolderTreeWidget extends StatefulWidget {
  final I18nService i18n;
  final List<String> selectedPath;
  final ValueChanged<List<String>> onFolderSelected;
  final VoidCallback? onCreateFolder;
  final OnItemDropped? onItemDropped;
  final OnFolderAction? onFolderAction;

  const FolderTreeWidget({
    super.key,
    required this.i18n,
    required this.selectedPath,
    required this.onFolderSelected,
    this.onCreateFolder,
    this.onItemDropped,
    this.onFolderAction,
  });

  @override
  State<FolderTreeWidget> createState() => _FolderTreeWidgetState();
}

class _FolderTreeWidgetState extends State<FolderTreeWidget> {
  final InventoryService _service = InventoryService();
  final Map<String, bool> _expanded = {};
  final Map<String, List<InventoryFolder>> _subfolders = {};
  List<InventoryFolder> _rootFolders = [];
  bool _loading = true;
  late String _langCode;
  String? _dragHoverPath; // Track which folder is being hovered during drag

  @override
  void initState() {
    super.initState();
    _langCode = widget.i18n.currentLanguage.split('_').first.toUpperCase();
    _loadRootFolders();
  }

  Future<void> _loadRootFolders() async {
    setState(() => _loading = true);
    try {
      // Ensure templates folder exists
      await _service.ensureTemplatesFolder();
      _rootFolders = await _service.getRootFolders();
      // Auto-expand selected path
      for (int i = 0; i < widget.selectedPath.length; i++) {
        final pathKey = widget.selectedPath.sublist(0, i + 1).join('/');
        _expanded[pathKey] = true;
        if (i < widget.selectedPath.length - 1) {
          await _loadSubfolders(widget.selectedPath.sublist(0, i + 1));
        }
      }
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

  bool _isSelected(List<String> folderPath) {
    if (folderPath.length != widget.selectedPath.length) return false;
    for (int i = 0; i < folderPath.length; i++) {
      if (folderPath[i] != widget.selectedPath[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Root (All Items) entry
        _buildFolderTile(
          context,
          theme,
          folderPath: [],
          name: widget.i18n.t('inventory_all_items'),
          icon: Icons.inventory_2,
          depth: 0,
          hasSubfolders: _rootFolders.isNotEmpty,
        ),
        // Root folders
        ..._rootFolders.map((folder) => _buildFolderTree(
              context,
              theme,
              folder,
              [folder.id],
            )),
        const SizedBox(height: 16),
        // Create folder button
        if (widget.onCreateFolder != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              onPressed: widget.onCreateFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              label: Text(widget.i18n.t('inventory_create_folder')),
            ),
          ),
      ],
    );
  }

  Widget _buildFolderTree(
    BuildContext context,
    ThemeData theme,
    InventoryFolder folder,
    List<String> folderPath,
  ) {
    final key = folderPath.join('/');
    final isExpanded = _expanded[key] ?? false;
    final subfolders = _subfolders[key] ?? [];
    final canHaveSubfolders = folder.canCreateSubfolder;
    // Templates folder is special - cannot be renamed/deleted
    final isTemplatesFolder = folderPath.length == 1 &&
        folderPath.first == InventoryService.templatesFolderId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFolderTile(
          context,
          theme,
          folderPath: folderPath,
          name: folder.getName(_langCode),
          icon: isTemplatesFolder ? Icons.library_books : Icons.folder,
          depth: folder.depth,
          hasSubfolders: canHaveSubfolders,
          isExpanded: isExpanded,
          isSpecialFolder: isTemplatesFolder,
          onExpand: canHaveSubfolders ? () => _toggleExpanded(folderPath) : null,
        ),
        if (isExpanded)
          ...subfolders.map((subfolder) => _buildFolderTree(
                context,
                theme,
                subfolder,
                [...folderPath, subfolder.id],
              )),
      ],
    );
  }

  Widget _buildFolderTile(
    BuildContext context,
    ThemeData theme, {
    required List<String> folderPath,
    required String name,
    required IconData icon,
    required int depth,
    bool hasSubfolders = false,
    bool isExpanded = false,
    bool isSpecialFolder = false,
    VoidCallback? onExpand,
  }) {
    final isSelected = _isSelected(folderPath);
    final pathKey = folderPath.join('/');
    final isDragHover = _dragHoverPath == pathKey;
    final leftPadding = 8.0 + (depth * 16.0);
    final canShowMenu = widget.onFolderAction != null &&
                        folderPath.isNotEmpty &&
                        !isSpecialFolder;

    final tile = Material(
      color: isDragHover
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.7)
          : isSelected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onFolderSelected(folderPath),
        onLongPress: canShowMenu ? () => _showFolderMenu(context, folderPath, name) : null,
        child: Padding(
          padding: EdgeInsets.only(
            left: leftPadding,
            right: 8,
            top: 8,
            bottom: 8,
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
                isDragHover ? Icons.folder_open : icon,
                size: 20,
                color: isDragHover
                    ? theme.colorScheme.primary
                    : isSelected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDragHover
                        ? theme.colorScheme.primary
                        : isSelected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurface,
                    fontWeight: isSelected || isDragHover ? FontWeight.w500 : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Three-dot menu for folder actions
              if (canShowMenu)
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onSelected: (action) {
                    widget.onFolderAction?.call(folderPath, action);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'rename',
                      child: Row(
                        children: [
                          const Icon(Icons.edit_outlined, size: 20),
                          const SizedBox(width: 12),
                          Text(widget.i18n.t('rename')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
                          const SizedBox(width: 12),
                          Text(widget.i18n.t('delete'), style: TextStyle(color: theme.colorScheme.error)),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );

    // Wrap with DragTarget if drag & drop is enabled
    if (widget.onItemDropped != null) {
      return DragTarget<Object>(
        onWillAcceptWithDetails: (details) {
          setState(() => _dragHoverPath = pathKey);
          return true;
        },
        onLeave: (_) {
          setState(() => _dragHoverPath = null);
        },
        onAcceptWithDetails: (details) {
          setState(() => _dragHoverPath = null);
          widget.onItemDropped!(details.data, folderPath);
        },
        builder: (context, candidateData, rejectedData) => tile,
      );
    }

    return tile;
  }

  void _showFolderMenu(BuildContext context, List<String> folderPath, String name) {
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
              child: Row(
                children: [
                  Icon(Icons.folder, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Rename
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(widget.i18n.t('rename')),
              onTap: () {
                Navigator.pop(context);
                widget.onFolderAction?.call(folderPath, 'rename');
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
                widget.onFolderAction?.call(folderPath, 'delete');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
